defmodule Pinchflat.LegacyMigration do
  @moduledoc """
  Detects and records positive legacy Pinchflat installation provenance
  prior to schema migrations running, holds mutating background jobs during
  pending migration review, runs on-disk media verification, and manages
  migration review lifecycle.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery
  require Logger

  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.LegacyMigration.Record
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Sources.CustomPoster
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.Utils.FilesystemUtils

  # The highest schema migration version in upstream / original Pinchflat
  @max_original_schema_version 20_250_317_213_740

  @mutating_queues [
    :default,
    :local_data,
    :media_fetching,
    :remote_metadata,
    :fast_indexing,
    :media_collection_indexing,
    :maintenance
  ]

  @doc """
  Runs before database migrations are executed.
  Inspects the database schema to determine whether it is a legacy Pinchflat
  database, an existing NGX database, or a fresh installation.
  """
  def pre_migration_check(repo) do
    case database_state(repo) do
      {:ok, state} ->
        state

      :before_migration ->
        state_file = state_file_path()

        cached =
          case File.stat(state_file) do
            {:ok, _} ->
              state = read_state(state_file)
              if state.status == "blocked", do: raise("Cannot read migration provenance; restore the config backup")
              state

            {:error, :enoent} ->
              nil

            {:error, _} ->
              raise "Cannot read migration provenance; check config permissions"
          end

        state = detect_and_persist_provenance(repo, state_file, cached)

        if state.status == "blocked",
          do: raise("Cannot establish migration provenance; check the database and config backup")

        state

      {:error, _} ->
        raise "Cannot read durable migration provenance"
    end
  end

  @doc """
  Returns true if positive legacy Pinchflat provenance was detected.
  """
  def legacy_provenance_detected? do
    case get_state() do
      %{provenance: "legacy_pinchflat"} -> true
      %{provenance: :legacy_pinchflat} -> true
      _ -> false
    end
  end

  @doc """
  Returns true if a legacy migration review is currently pending.
  """
  def legacy_migration_pending? do
    case get_state() do
      %{status: status} when status in ["pending_review", "pending_release", "blocked"] -> true
      _ -> false
    end
  end

  @doc """
  Records approval durably. Queue release completes the review lifecycle.
  Also prepares and schedules missing channel artwork repairs if needed.
  """
  def complete_review! do
    case Repo.one(Record) do
      %Record{provenance: "legacy_pinchflat", status: status} = record
      when status in ["pending_review", "pending_release", "completed"] ->
        new_status = if(status == "completed", do: "completed", else: "pending_release")
        confirmed_at = record.confirmed_at || DateTime.utc_now() |> DateTime.truncate(:second)

        missing_sources = missing_channel_artwork_sources()
        missing_ids = Enum.map(missing_sources, & &1.id)

        repairs = record.artwork_repairs || %{}
        enqueued_ids = Map.get(repairs, "enqueued_source_ids", [])
        to_enqueue = Enum.reject(missing_sources, &(&1.id in enqueued_ids))

        initial_repairs = %{
          "status" => if(missing_ids == [] or to_enqueue == [], do: "completed", else: "pending"),
          "missing_source_ids" => missing_ids,
          "enqueued_source_ids" => enqueued_ids,
          "failed_source_ids" => Map.get(repairs, "failed_source_ids", []),
          "total_missing" => length(missing_ids),
          "enqueued_count" => length(enqueued_ids),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        changeset =
          Ecto.Changeset.change(record,
            status: new_status,
            confirmed_at: confirmed_at,
            artwork_repairs: if(record.artwork_repairs, do: record.artwork_repairs, else: initial_repairs)
          )

        case Repo.update(changeset) do
          {:ok, updated_record} ->
            # Approval is durable in the database. Updating its cache is best effort.
            write_state(get_state())
            enqueue_missing_channel_artwork_tasks(updated_record, to_enqueue)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :unknown_provenance}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Enqueues artwork repair tasks for any channel sources missing UI artwork.
  Updates the artwork_repairs tracking map durably.
  """
  def enqueue_missing_channel_artwork_tasks do
    case Repo.one(Record) do
      %Record{} = record ->
        missing_sources = missing_channel_artwork_sources()
        missing_ids = Enum.map(missing_sources, & &1.id)

        repairs = record.artwork_repairs || %{}
        enqueued_ids = Map.get(repairs, "enqueued_source_ids", [])
        to_enqueue = Enum.reject(missing_sources, &(&1.id in enqueued_ids))

        initial_repairs = %{
          "status" => if(missing_ids == [] or to_enqueue == [], do: "completed", else: "pending"),
          "missing_source_ids" => missing_ids,
          "enqueued_source_ids" => enqueued_ids,
          "failed_source_ids" => Map.get(repairs, "failed_source_ids", []),
          "total_missing" => length(missing_ids),
          "enqueued_count" => length(enqueued_ids),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        record =
          record
          |> Ecto.Changeset.change(artwork_repairs: initial_repairs)
          |> Repo.update!()

        enqueue_missing_channel_artwork_tasks(record, to_enqueue)

      nil ->
        {:error, :no_record}
    end
  end

  @doc """
  Enqueues artwork repair tasks for a list of sources, updating Record incrementally.
  """
  def enqueue_missing_channel_artwork_tasks(%Record{} = record, to_enqueue) do
    Enum.reduce(to_enqueue, record, fn source, current_record ->
      repairs = current_record.artwork_repairs || %{}
      enqueued_ids = Map.get(repairs, "enqueued_source_ids", [])
      failed_ids = Map.get(repairs, "failed_source_ids", [])

      case SourceMetadataStorageWorker.kickoff_with_task(source,
             mode: "artwork_repair",
             unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]
           ) do
        {:ok, _task} ->
          new_enqueued = Enum.uniq([source.id | enqueued_ids])
          new_failed = List.delete(failed_ids, source.id)

          updated_repairs =
            repairs
            |> Map.put("enqueued_source_ids", new_enqueued)
            |> Map.put("failed_source_ids", new_failed)
            |> Map.put("enqueued_count", length(new_enqueued))
            |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

          current_record
          |> Ecto.Changeset.change(artwork_repairs: updated_repairs)
          |> Repo.update!()

        {:error, :duplicate_job} ->
          new_enqueued = Enum.uniq([source.id | enqueued_ids])

          updated_repairs =
            repairs
            |> Map.put("enqueued_source_ids", new_enqueued)
            |> Map.put("enqueued_count", length(new_enqueued))
            |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

          current_record
          |> Ecto.Changeset.change(artwork_repairs: updated_repairs)
          |> Repo.update!()

        {:error, reason} ->
          Logger.warning(
            "[LegacyMigration] Failed to enqueue artwork repair for source ##{source.id}: #{inspect(reason)}"
          )

          new_failed = Enum.uniq([source.id | failed_ids])

          updated_repairs =
            repairs
            |> Map.put("failed_source_ids", new_failed)
            |> Map.put("status", "incomplete")
            |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

          current_record
          |> Ecto.Changeset.change(artwork_repairs: updated_repairs)
          |> Repo.update!()
      end
    end)
    |> finalize_artwork_repair_status()
  end

  @doc """
  Resumes any incomplete or pending artwork repair tasks after application boot.
  """
  def resume_artwork_repairs! do
    case Repo.one(Record) do
      %Record{artwork_repairs: %{"status" => status} = repairs} = record
      when status in ["pending", "incomplete"] ->
        missing_ids = Map.get(repairs, "missing_source_ids", [])
        enqueued_ids = Map.get(repairs, "enqueued_source_ids", [])
        remaining_ids = missing_ids -- enqueued_ids

        if remaining_ids != [] do
          Logger.info("[LegacyMigration] Resuming artwork repair for #{length(remaining_ids)} channel sources")

          sources =
            Repo.all(from s in Source, where: s.id in ^remaining_ids, preload: [:metadata, :media_profile])

          enqueue_missing_channel_artwork_tasks(record, sources)
          :ok
        else
          finalize_artwork_repair_status(record)
          :ok
        end

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("[LegacyMigration] Could not resume artwork repairs: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Retries failed artwork repairs or re-scans channels missing artwork.
  """
  def retry_artwork_repairs! do
    case Repo.one(Record) do
      %Record{} = record ->
        missing_sources = missing_channel_artwork_sources()
        missing_ids = Enum.map(missing_sources, & &1.id)

        repairs = %{
          "status" => if(missing_ids == [], do: "completed", else: "pending"),
          "missing_source_ids" => missing_ids,
          "enqueued_source_ids" => [],
          "failed_source_ids" => [],
          "total_missing" => length(missing_ids),
          "enqueued_count" => 0,
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        record =
          record
          |> Ecto.Changeset.change(artwork_repairs: repairs)
          |> Repo.update!()

        enqueue_missing_channel_artwork_tasks(record, missing_sources)
        {:ok, artwork_repair_status()}

      nil ->
        {:error, :no_record}
    end
  end

  @doc """
  Returns current artwork repair status map.
  """
  def artwork_repair_status do
    case Repo.one(Record) do
      %Record{artwork_repairs: repairs} when is_map(repairs) -> repairs
      _ -> %{"status" => "none", "total_missing" => 0, "enqueued_count" => 0}
    end
  rescue
    _ -> %{"status" => "none", "total_missing" => 0, "enqueued_count" => 0}
  end

  @doc """
  Returns channel sources that are missing any supported UI artwork (poster or banner/fanart)
  or have artwork paths referencing missing files on disk.
  """
  def missing_channel_artwork_sources do
    Repo.all(from s in Source, where: s.collection_type == :channel, preload: [:metadata, :media_profile])
    |> Enum.filter(&channel_artwork_missing?/1)
  end

  @doc """
  Returns true if a channel source is missing its UI poster artwork, or has a
  referenced poster file missing on disk. Returns false for non-channel collections.
  Distinguishes source UI artwork (stored under `/config/metadata/<source>/`) from
  optional media-center artwork in downloads.
  """
  def channel_artwork_missing?(source) do
    if source.collection_type == :channel do
      source = Repo.preload(source, :metadata)
      channel_poster_missing?(source)
    else
      false
    end
  end

  defp channel_poster_missing?(source) do
    custom_poster = CustomPoster.filepath(source)

    if is_binary(custom_poster) and File.exists?(custom_poster) do
      false
    else
      ui_poster = source.metadata && source.metadata.poster_filepath
      !is_binary(ui_poster) or !File.exists?(ui_poster)
    end
  end

  defp finalize_artwork_repair_status(%Record{} = record) do
    repairs = record.artwork_repairs || %{}
    missing_ids = Map.get(repairs, "missing_source_ids", [])
    enqueued_ids = Map.get(repairs, "enqueued_source_ids", [])
    failed_ids = Map.get(repairs, "failed_source_ids", [])

    status =
      cond do
        missing_ids == [] -> "completed"
        failed_ids != [] -> "incomplete"
        missing_ids -- enqueued_ids == [] -> "completed"
        true -> "pending"
      end

    if Map.get(repairs, "status") != status do
      record
      |> Ecto.Changeset.change(artwork_repairs: Map.put(repairs, "status", status))
      |> Repo.update!()
    else
      record
    end
  end

  @doc """
  Returns current migration review state.
  """
  def get_state do
    case database_state(Repo) do
      {:ok, state} ->
        # JSON is a disposable scan cache after migration, never review approval.
        case read_state(state_file_path()) do
          %{last_scan: scan} when is_map(scan) -> Map.put(state, :last_scan, scan)
          _ -> state
        end

      :before_migration ->
        read_state(state_file_path())

      {:error, _} ->
        blocked_state()
    end
  end

  @doc """
  Returns the list of queues that mutate media or perform remote indexing.
  """
  def mutating_queues do
    Enum.uniq(@mutating_queues ++ Keyword.keys(Application.get_env(:pinchflat, Oban, [])[:queues] || []))
  end

  @doc """
  Starts Oban with the review hold already applied, including supervisor restarts.
  """
  def start_oban_link(config), do: Oban.start_link(prepare_oban_config(config))

  @doc """
  Persists pre-review pause choices before any queue is allowed to execute.
  """
  def prepare_oban_config(config) do
    if Keyword.has_key?(config, :testing) do
      config
    else
      queues = Keyword.get(config, :queues, [])

      if legacy_migration_pending?() do
        pauses =
          Map.new(queues, fn {queue, opts} ->
            {Atom.to_string(queue), is_list(opts) && Keyword.get(opts, :paused, false)}
          end)

        persist_queue_pauses!(pauses)

        Keyword.put(
          config,
          :queues,
          Enum.map(queues, fn {queue, opts} -> {queue, Keyword.put(queue_options(opts), :paused, true)} end)
        )
      else
        restore_configured_pauses(config, queues)
      end
    end
  end

  @doc """
  Pauses mutating Oban queues during pending migration review.
  """
  def hold_mutating_queues! do
    if legacy_migration_pending?() && !oban_testing?() do
      queues = Oban.config().queues
      pauses = Map.new(queues, fn {queue, _} -> {Atom.to_string(queue), Oban.check_queue(queue: queue).paused} end)
      persist_queue_pauses!(pauses)
      Enum.each(queues, fn {queue, _} -> :ok = Oban.pause_queue(queue: queue) end)
    end

    :ok
  end

  @doc """
  Resumes review-held queues after approval, reapplies concurrency limits,
  and records completion. Failed release remains retryable with approval retained.
  """
  def release_mutating_queues! do
    if get_state().status in ["pending_review", "blocked"] do
      {:error, :review_pending}
    else
      unless oban_testing?() do
        resume_review_queues()
        Pinchflat.Settings.QueueConcurrency.apply!()
      end

      case Repo.one(Record) do
        %Record{status: "pending_release"} = record ->
          record |> Ecto.Changeset.change(status: "completed") |> Repo.update!()

        _ ->
          :ok
      end

      :ok
    end
  rescue
    error ->
      hold_after_release_error()
      {:error, error}
  end

  @doc """
  Runs on-disk library verification comparing recorded database downloads against
  actual files and mounts on the filesystem.
  """
  def verify_library do
    lock = {{__MODULE__, :scan}, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        do_verify_library()
      rescue
        _ ->
          Logger.warning("[LegacyMigration] Library verification failed; background review remains held")

          summary =
            cached_summary()
            |> Map.merge(%{
              status: :error,
              complete: false,
              error: "Library verification failed. Check database and config access, then retry."
            })

          write_state(Map.put(get_state(), :last_scan, summary))
          summary
      after
        :global.del_lock(lock, [node()])
      end
    else
      cached_summary()
    end
  end

  @doc """
  Starts read-only verification outside the web request. Existing scans are retained.
  """
  def start_verification do
    if verification_running?() do
      {:ok, :already_running}
    else
      summary = empty_summary()
      :ok = write_state(Map.put(get_state(), :last_scan, summary))

      case Task.Supervisor.start_child(Pinchflat.LegacyMigration.ScanSupervisor, fn -> verify_library() end) do
        {:ok, _} -> {:ok, :started}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _ -> {:error, :scan_unavailable}
  end

  @doc """
  Returns saved progress without running a blocking scan in the web request.
  """
  def get_or_run_verification do
    case get_state() do
      %{last_scan: scan} when is_map(scan) ->
        summary = normalize_summary(scan)

        cond do
          summary.status == :running and !verification_running?() ->
            interrupted =
              Map.merge(summary, %{
                status: :interrupted,
                complete: false,
                error: "The scan stopped before finishing. Retry the scan to check the whole library."
              })

            write_state(Map.put(get_state(), :last_scan, interrupted))
            interrupted

          summary.complete and summary.scan_session != Application.get_env(:pinchflat, :legacy_migration_scan_session) ->
            case start_verification() do
              {:ok, _} ->
                empty_summary()

              {:error, _} ->
                Map.merge(empty_summary(), %{
                  status: :error,
                  error: "Could not refresh verification. Check config access, then retry."
                })
            end

          true ->
            summary
        end

      _ ->
        case start_verification() do
          {:ok, _} ->
            empty_summary()

          {:error, _} ->
            Map.merge(empty_summary(), %{
              status: :error,
              error: "Could not start verification. Check config access, then retry."
            })
        end
    end
  end

  defp do_verify_library do
    query = where(MediaQuery.new(), ^MediaQuery.downloaded())

    summary =
      Map.merge(empty_summary(), %{
        sources_count: Repo.aggregate(Source, :count, :id),
        media_profiles_count: Repo.aggregate(MediaProfile, :count, :id),
        db_downloaded_count: Repo.aggregate(query, :count, :id),
        db_downloaded_bytes: max(Repo.aggregate(query, :sum, :media_size_bytes) || 0, 0),
        totals_ready: true
      })

    upper_id = Repo.aggregate(query, :max, :id) || 0
    :ok = publish_scan(summary)
    summary = scan_batches(query, 0, upper_id, summary)
    complete = summary.processed_count == summary.db_downloaded_count

    status =
      cond do
        !complete ->
          :partial

        summary.missing_count > 0 or !summary.mounts.media_accessible or !summary.mounts.config_accessible ->
          :issues_detected

        true ->
          :ok
      end

    summary =
      Map.merge(summary, %{status: status, complete: complete, scanned_at: DateTime.utc_now() |> DateTime.to_iso8601()})

    :ok = publish_scan(summary)
    summary
  end

  defp scan_batches(query, last_id, upper_id, summary) do
    items =
      Repo.all(
        from mi in exclude(query, :order_by),
          where: mi.id > ^last_id and mi.id <= ^upper_id,
          order_by: [asc: mi.id],
          limit: 250,
          select: %{id: mi.id, title: mi.title, filepath: mi.media_filepath, expected_size: mi.media_size_bytes}
      )

    case items do
      [] ->
        summary

      _ ->
        updated =
          Enum.reduce(items, summary, fn item, acc ->
            acc = Map.update!(acc, :processed_count, &(&1 + 1))

            case verify_item_file(item.filepath) do
              {:ok, size} ->
                %{acc | verified_count: acc.verified_count + 1, verified_bytes: acc.verified_bytes + size}

              {:error, reason} ->
                entry = Map.put(item, :error, to_string(reason))
                sample = if length(acc.missing_items) < 20, do: acc.missing_items ++ [entry], else: acc.missing_items
                %{acc | missing_count: acc.missing_count + 1, missing_items: sample}
            end
          end)

        :ok = publish_scan(updated)
        scan_batches(query, List.last(items).id, upper_id, updated)
    end
  end

  defp publish_scan(summary), do: write_state(Map.put(get_state(), :last_scan, summary))

  defp cached_summary do
    case get_state() do
      %{last_scan: scan} when is_map(scan) -> normalize_summary(scan)
      _ -> empty_summary()
    end
  end

  defp normalize_summary(scan) do
    counts = [
      :sources_count,
      :media_profiles_count,
      :db_downloaded_count,
      :db_downloaded_bytes,
      :verified_count,
      :verified_bytes,
      :missing_count
    ]

    if Enum.all?(counts, &(is_integer(scan[&1]) and scan[&1] >= 0)) and valid_scan_fields?(scan) do
      status =
        case scan[:status] do
          value when value in ["ok", :ok] -> :ok
          value when value in ["issues_detected", :issues_detected] -> :issues_detected
          value when value in ["running", :running] -> :running
          value when value in ["interrupted", :interrupted] -> :interrupted
          value when value in ["partial", :partial] -> :partial
          _ -> :error
        end

      defaults = empty_summary()

      Map.merge(defaults, scan)
      |> Map.put(:mounts, Map.merge(defaults.mounts, scan.mounts))
      |> Map.put(:scan_session, Map.get(scan, :scan_session))
      |> Map.put(:status, status)
      |> Map.put(:complete, status in [:ok, :issues_detected] and Map.get(scan, :complete, true))
      |> Map.put(:totals_ready, Map.get(scan, :totals_ready, true))
    else
      Map.merge(empty_summary(), %{status: :error, error: "Saved scan results could not be read. Retry verification."})
    end
  end

  defp valid_scan_fields?(scan) do
    mounts = scan[:mounts]
    complete = Map.get(scan, :complete, true)
    processed = Map.get(scan, :processed_count, scan.verified_count + scan.missing_count)

    is_boolean(complete) and is_boolean(Map.get(scan, :totals_ready, true)) and
      is_integer(processed) and processed >= 0 and
      scan[:status] in [
        "ok",
        :ok,
        "issues_detected",
        :issues_detected,
        "running",
        :running,
        "interrupted",
        :interrupted,
        "partial",
        :partial,
        "error",
        :error
      ] and
      (is_nil(scan[:error]) or is_binary(scan[:error])) and
      (is_nil(scan[:scanned_at]) or is_binary(scan[:scanned_at])) and
      is_map(mounts) and is_boolean(mounts[:media_accessible]) and is_boolean(mounts[:config_accessible]) and
      is_binary(mounts[:media_directory]) and is_binary(mounts[:config_directory]) and
      is_list(scan[:missing_items]) and Enum.all?(scan.missing_items, &valid_scan_item?/1) and
      (!complete or scan[:status] not in ["ok", :ok, "issues_detected", :issues_detected] or
         (processed == scan.db_downloaded_count and scan.verified_count + scan.missing_count == processed))
  end

  defp valid_scan_item?(item) when is_map(item) do
    is_integer(item[:id]) and (is_nil(item[:title]) or is_binary(item[:title])) and
      (is_nil(item[:filepath]) or is_binary(item[:filepath])) and is_binary(item[:error])
  end

  defp valid_scan_item?(_), do: false

  defp verification_running? do
    Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor) != []
  catch
    :exit, _ -> false
  end

  defp empty_summary do
    media_dir = Application.get_env(:pinchflat, :media_directory, "/downloads")
    config_dir = System.get_env("CONFIG_PATH", "/config")

    %{
      sources_count: 0,
      media_profiles_count: 0,
      db_downloaded_count: 0,
      db_downloaded_bytes: 0,
      verified_count: 0,
      verified_bytes: 0,
      missing_count: 0,
      missing_items: [],
      processed_count: 0,
      totals_ready: false,
      complete: false,
      status: :running,
      error: nil,
      scanned_at: nil,
      scan_session: Application.get_env(:pinchflat, :legacy_migration_scan_session),
      mounts: %{
        media_directory: media_dir,
        media_accessible: match?({:ok, _}, File.ls(media_dir)),
        config_directory: config_dir,
        config_accessible: match?({:ok, _}, File.ls(config_dir))
      }
    }
  end

  @doc """
  Returns the path to the legacy migration state file.
  """
  def state_file_path do
    case Application.get_env(:pinchflat, :legacy_migration_state_path) do
      path when is_binary(path) ->
        path

      _ ->
        config_dir = System.get_env("CONFIG_PATH", "/config")
        Path.join(config_dir, "legacy_migration_state.json")
    end
  end

  defp verify_item_file(nil), do: {:error, :missing_path}
  defp verify_item_file(""), do: {:error, :missing_path}

  defp verify_item_file(filepath) do
    case File.stat(filepath) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        case File.open(filepath, [:read, :binary]) do
          {:ok, file} ->
            File.close(file)
            {:ok, size}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _} ->
        {:error, :not_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp oban_testing? do
    case Application.get_env(:pinchflat, Oban) do
      config when is_list(config) -> Keyword.has_key?(config, :testing)
      _ -> false
    end
  end

  defp hold_after_release_error do
    hold_mutating_queues!()
  rescue
    _ -> :ok
  end

  defp detect_and_persist_provenance(repo, state_file, cached) do
    provenance =
      try do
        case check_schema(repo) do
          {:legacy_pinchflat, max_v, count} ->
            Logger.info(
              "[LegacyMigration] Positive legacy Pinchflat provenance detected (max_version: #{max_v}, sources: #{count})"
            )

            %{
              provenance: "legacy_pinchflat",
              status: "pending_review",
              detected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
              original_max_version: max_v,
              source_count: count,
              original_database_identity: database_identity(repo)
            }

          {:existing_ngx, max_v} ->
            Logger.info("[LegacyMigration] Existing NGX installation detected (max_version: #{max_v})")

            %{
              provenance: "existing_ngx",
              status: "completed",
              detected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
              max_version: max_v
            }

          :fresh_install ->
            Logger.info("[LegacyMigration] Fresh installation detected")

            %{
              provenance: "fresh_install",
              status: "completed",
              detected_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }
        end
      rescue
        e ->
          Logger.warning("[LegacyMigration] Could not inspect schema before migration: #{inspect(e)}")

          %{
            provenance: "unknown",
            status: "blocked",
            error: inspect(e)
          }
      end

    provenance = bind_pending_provenance(provenance, cached, repo)

    :ok = write_state(provenance, state_file)
    provenance
  end

  defp check_schema(repo) do
    table_query =
      if repo_postgres?(repo),
        do: "SELECT to_regclass('schema_migrations')",
        else: "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'"

    case Ecto.Adapters.SQL.query(repo, table_query) do
      {:ok, %{rows: [[name]]}} when not is_nil(name) ->
        version_query = "SELECT count(*), max(version) FROM schema_migrations;"
        {:ok, %{rows: [[count, max_version]]}} = Ecto.Adapters.SQL.query(repo, version_query)

        max_v =
          cond do
            is_nil(max_version) -> nil
            is_binary(max_version) -> String.to_integer(max_version)
            is_integer(max_version) -> max_version
            true -> nil
          end

        if is_nil(max_v) or count == 0 do
          check_fresh_schema(repo)
        else
          if max_v <= @max_original_schema_version do
            check_original_schema(repo, max_v, count)
          else
            [[ngx_markers]] =
              Ecto.Adapters.SQL.query!(repo, "SELECT count(*) FROM schema_migrations WHERE version=20260910160000").rows

            if ngx_markers != 1, do: raise("Migration history is not a recognized NGX database")
            {:existing_ngx, max_v}
          end
        end

      {:ok, %{rows: rows}} when rows in [[], [[nil]]] ->
        check_fresh_schema(repo)

      {:error, _} ->
        raise "Cannot inspect migration history"
    end
  end

  defp check_fresh_schema(repo) do
    sql =
      if repo_postgres?(repo),
        do:
          "SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name IN ('sources','media_items','settings','media_profiles')",
        else:
          "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('sources','media_items','settings','media_profiles')"

    [[count]] = Ecto.Adapters.SQL.query!(repo, sql).rows
    if count != 0, do: raise("Application tables exist without a valid migration history")
    :fresh_install
  end

  defp check_original_schema(repo, max_version, count) do
    if max_version != @max_original_schema_version or count != 77,
      do: raise("Update the original Pinchflat to its latest image before migrating")

    if repo_postgres?(repo),
      do: raise("Legacy migration requires a SQLite database")

    columns = Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(sources)").rows |> Enum.map(&Enum.at(&1, 1))

    if "custom_name" not in columns or "custom_name_locked" in columns,
      do: raise("Source schema does not match the original migration history")

    [[count]] = Ecto.Adapters.SQL.query!(repo, "SELECT count(*) FROM sources").rows
    {:legacy_pinchflat, max_version, count}
  end

  defp database_identity(repo) do
    case Ecto.Adapters.SQL.query!(repo, "SELECT route_token FROM settings ORDER BY id LIMIT 1").rows do
      [[token]] when is_binary(token) and token != "" ->
        :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      _ ->
        raise "Cannot identify the original database"
    end
  end

  defp bind_pending_provenance(
         %{provenance: detected},
         %{provenance: "legacy_pinchflat", status: "pending_review"} = cached,
         repo
       )
       when detected in ["existing_ngx", "unknown"] do
    # A migration may have stopped before the NGX marker/audit table was added.
    # Bind its earlier positive observation to this DB instead of trusting the path.
    Ecto.Adapters.SQL.query!(repo, "SELECT count(*) FROM sources")
    if cached[:original_database_identity] == database_identity(repo), do: cached, else: blocked_state()
  rescue
    _ -> blocked_state()
  end

  defp bind_pending_provenance(
         %{provenance: "fresh_install"},
         %{provenance: "legacy_pinchflat", status: "pending_review"},
         _repo
       ),
       do: blocked_state()

  defp bind_pending_provenance(detected, _cached, _repo), do: detected

  defp read_state(file) do
    result =
      case File.stat(file) do
        {:ok, %File.Stat{size: size}} when size <= 1_048_576 -> File.read(file)
        _ -> {:error, :unreadable_cache}
      end

    case result do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms!) do
          {:ok, %{provenance: provenance, status: status} = data}
          when provenance in ["legacy_pinchflat", "existing_ngx", "fresh_install", "existing_or_fresh"] and
                 status in ["pending_review", "pending_release", "completed"] ->
            data

          _ ->
            blocked_state()
        end

      _ ->
        blocked_state()
    end
  rescue
    _ -> blocked_state()
  end

  defp blocked_state, do: %{provenance: "unknown", status: "blocked"}

  defp restore_configured_pauses(config, queues) do
    case Repo.one(Record) do
      %Record{queue_pauses: pauses} when is_map(pauses) ->
        restored =
          Enum.map(queues, fn {queue, opts} ->
            if pauses[Atom.to_string(queue)] == true,
              do: {queue, Keyword.put(queue_options(opts), :paused, true)},
              else: {queue, opts}
          end)

        Keyword.put(config, :queues, restored)

      _ ->
        config
    end
  end

  defp resume_review_queues do
    case Repo.one(Record) do
      %Record{queue_pauses: pauses} when is_map(pauses) ->
        Enum.each(Oban.config().queues, fn {queue, _} ->
          if pauses[Atom.to_string(queue)] == false, do: :ok = Oban.resume_queue(queue: queue)
        end)

      _ ->
        :ok
    end
  end

  defp database_state(repo) do
    table_sql =
      if repo_postgres?(repo),
        do: "SELECT to_regclass('legacy_migration_records')",
        else: "SELECT name FROM sqlite_master WHERE type='table' AND name='legacy_migration_records'"

    case Ecto.Adapters.SQL.query!(repo, table_sql).rows do
      rows when rows in [[], [[nil]]] ->
        :before_migration

      _ ->
        case repo.one(
               from r in Record,
                 select:
                   map(r, [
                     :provenance,
                     :status,
                     :confirmed_at,
                     :original_max_version,
                     :original_source_count,
                     :artwork_repairs
                   ])
             ) do
          %{provenance: provenance, status: status} = state
          when provenance in ["legacy_pinchflat", "existing_or_fresh"] and
                 status in ["pending_review", "pending_release", "completed"] ->
            {:ok, state}

          _ ->
            {:error, :missing_record}
        end
    end
  rescue
    error -> {:error, error}
  end

  defp repo_postgres?(repo), do: repo.__adapter__() == Ecto.Adapters.Postgres

  defp queue_options(limit) when is_integer(limit), do: [limit: limit]
  defp queue_options(options), do: options

  defp persist_queue_pauses!(pauses) do
    case Repo.one!(Record) do
      %Record{queue_pauses: nil} = record ->
        record |> Ecto.Changeset.change(queue_pauses: pauses) |> Repo.update!()

      %Record{queue_pauses: previous} = record when is_map(previous) ->
        merged = Map.merge(pauses, previous)
        if merged == previous, do: record, else: record |> Ecto.Changeset.change(queue_pauses: merged) |> Repo.update!()

      record ->
        record
    end
  end

  defp write_state(data, file \\ nil) do
    target_file = file || state_file_path()
    content = Jason.encode!(data, pretty: true)
    temporary = target_file <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- FilesystemUtils.write_p(temporary, content), :ok <- File.rename(temporary, target_file) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end
end
