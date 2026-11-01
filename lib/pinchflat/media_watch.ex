defmodule Pinchflat.MediaWatch do
  @moduledoc """
  Context for prospective watch enrollment and watch/event persistence.

  M1 scope: default-off schema, prospective enrollment on first completed
  local download, immutable baseline, and non-destructive persistence.
  Destructive preservation/replacement remains gated for M2.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Pinchflat.Downloading.FirstArtifact
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.MediaWatch.Lease
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.MediaWatchEvent, as: Event
  alias Pinchflat.MediaWatch.NotificationWorker
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.MediaWatch.ReplacementIntent
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @lease_seconds 60
  @recovery_batch_size 10
  @observation_confirmation_seconds 15 * 60
  @observation_success_seconds 6 * 60 * 60
  @observation_min_backoff_seconds 15 * 60
  @observation_max_backoff_seconds 6 * 60 * 60
  @observation_jitter_seconds 10 * 60

  @doc """
  Returns the effective watch window (days) for a source, or 0 when disabled.
  """
  @spec effective_watch_window_days(Source.t()) :: non_neg_integer()
  def effective_watch_window_days(%Source{} = source) do
    Source.effective_watch_window_days(source)
  end

  @doc """
  Finishes a previously finalized first download. The pending marker is written
  only after application postprocessing succeeds; failures of this transaction
  leave it in place so a retry uses the existing artifact, not yt-dlp.

  Returns {:ok, MediaItem.t()} | {:error, term()}.
  """
  def complete_pending_download(%MediaItem{id: id}) do
    Repo.transaction(fn ->
      # A real write first reserves the row on SQLite and locks it on PostgreSQL.
      # A second worker must re-read completion/policy after acquiring the row.
      Repo.update_all(from(item in MediaItem, where: item.id == ^id),
        set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      item = Repo.get!(MediaItem, id) |> Repo.preload(source: :media_profile)

      cond do
        item.media_downloaded_at ->
          item

        is_nil(item.watch_enrollment_pending_at) or item.watch_postprocessing_pending ->
          Repo.rollback(:not_finalized)

        is_nil(item.watch_download_started_at) ->
          Repo.rollback(:not_prospective)

        true ->
          case pending_artifact_approval(item) do
            {:ok, approved} -> complete_approved_download(item, approved)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp complete_approved_download(item, approved) do
    case enroll_on_first_completion(item, item.source,
           first_completion: true,
           completed_at: item.watch_enrollment_pending_at
         ) do
      {:ok, %Watch{} = watch} ->
        case update_watch(watch, %{approved_active_files: Map.put(approved, "first", approved)}) do
          {:ok, _} -> complete_first_item(item)
          {:error, reason} -> Repo.rollback(reason)
        end

      {:ok, _} ->
        complete_first_item(item)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp complete_first_item(item) do
    case Media.update_media_item(item, %{
           media_downloaded_at: item.watch_enrollment_pending_at,
           watch_enrollment_pending_at: nil,
           watch_postprocessing_pending: false,
           watch_download_started_at: nil
         }) do
      {:ok, completed} -> completed
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp pending_artifact_approval(item) do
    if FirstArtifact.pending?(item) do
      FirstArtifact.completed_approval(item)
    else
      if effective_watch_window_days(item.source) == 0,
        do: {:ok, nil},
        else: {:error, :invalid_first_artifact_journal}
    end
  end

  @doc """
  Enrolls a watch prospectively for a media item on its first completed local
  download, when the effective watch window is greater than zero.

  Idempotent: an existing watch for the media item is left untouched, so
  redownloads never restart the window or replace the baseline.
  """
  @spec enroll_on_first_completion(MediaItem.t(), Source.t() | nil, keyword()) ::
          {:ok, Watch.t()} | {:ok, :disabled} | {:ok, :already_enrolled} | {:ok, :not_eligible} | {:error, term()}
  def enroll_on_first_completion(%MediaItem{} = media_item, source, opts \\ []) do
    first_completion? = Keyword.get(opts, :first_completion, true)

    days = effective_watch_window_days_for_source(source)

    cond do
      days <= 0 ->
        {:ok, :disabled}

      not first_completion? or not is_nil(media_item.media_downloaded_at) ->
        {:ok, :already_enrolled}

      Repo.get_by(Watch, media_item_id: media_item.id) != nil ->
        {:ok, :already_enrolled}

      not File.regular?(media_item.media_filepath || "") ->
        {:error, :missing_local_media}

      true ->
        now = Keyword.get(opts, :completed_at) || DateTime.utc_now() |> DateTime.truncate(:second)
        ends_at = DateTime.add(now, days * 86_400, :second)

        upstream_duration = Keyword.get(opts, :upstream_duration_seconds)

        attrs = %{
          media_item_id: media_item.id,
          media_item_uuid: media_item.uuid,
          media_id: media_item.media_id,
          source_id: media_item.source_id,
          source_uuid: (source && source.uuid) || nil,
          started_at: now,
          ends_at: ends_at,
          baseline_upstream_duration_seconds: upstream_duration,
          baseline_visibility: availability_to_string(media_item.availability),
          next_check_at: now,
          observation_version: 0,
          archive_state: "none",
          confirmed_state: "unchanged"
        }

        %Watch{}
        |> Watch.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, watch} ->
            {:ok, watch}

          {:error, changeset} ->
            if unique_constraint_error?(changeset) do
              {:ok, :already_enrolled}
            else
              {:error, changeset}
            end
        end
    end
  end

  defp decide_observation(_watch, %Observation{livestream: true} = observation, now, jitter) do
    {:ok,
     %{
       last_observed_at: now,
       last_error_at: now,
       observed_visibility: Observation.current_visibility(observation),
       next_check_at: DateTime.add(now, @observation_min_backoff_seconds + jitter, :second)
     }, nil}
  end

  defp decide_observation(watch, observation, now, jitter) do
    case Observation.classify(watch, observation) do
      {:unknown, _reason} ->
        error_count = watch.error_count + 1

        {:ok,
         %{
           last_observed_at: now,
           last_error_at: now,
           error_count: error_count,
           next_check_at: DateTime.add(now, observation_backoff(error_count) + jitter, :second)
         }, nil}

      :unchanged ->
        {:ok, success_attributes(watch, observation, now, jitter), nil}

      {kind, old_value, new_value} ->
        decide_change(watch, observation, now, jitter, kind, old_value, new_value)
    end
  end

  defp decide_change(watch, observation, now, jitter, kind, old_value, new_value) do
    success = success_attributes(watch, observation, now, jitter)

    if watch.confirmed_state == "suspected" and watch.suspected_kind == to_string(kind) and
         watch.suspected_first_seen_at != nil and compatible_evidence?(watch, new_value) do
      confirm_or_extend_suspicion(watch, observation, now, jitter, success, kind, old_value, new_value)
    else
      attrs =
        success
        |> Map.drop([:last_success_at, :next_check_at, :current_visibility])
        |> Map.merge(%{
          confirmed_state: "suspected",
          suspected_kind: to_string(kind),
          suspected_value: to_string(new_value),
          suspected_first_seen_at: now,
          suspected_count: 1,
          hold_reason: "watch change: #{kind}",
          hold_at: now,
          next_check_at: next_confirmation_at(now, now, jitter)
        })

      {:ok, attrs, nil}
    end
  end

  defp confirm_or_extend_suspicion(watch, observation, now, jitter, success, kind, old_value, new_value) do
    first_seen = watch.suspected_first_seen_at
    elapsed = DateTime.diff(now, first_seen, :second)

    if elapsed >= @observation_confirmation_seconds do
      attrs =
        success
        |> Map.merge(%{
          confirmed_state: "confirmed",
          confirmed_change_at: watch.confirmed_change_at || now,
          suspected_kind: watch.suspected_kind,
          suspected_value: to_string(new_value),
          suspected_count: watch.suspected_count + 1,
          hold_reason: watch.hold_reason || "watch change: #{kind}",
          hold_at: watch.hold_at || first_seen
        })

      attrs = if kind == :duration, do: Map.put(attrs, :confirmed_upstream_duration_seconds, new_value), else: attrs

      {:ok, attrs, build_event_attributes(to_string(kind), old_value, new_value, now)}
    else
      attrs = %{
        last_observed_at: now,
        last_error_at: Map.get(success, :last_error_at),
        error_count: 0,
        observed_visibility: Observation.current_visibility(observation),
        suspected_kind: watch.suspected_kind,
        suspected_value: to_string(new_value),
        suspected_first_seen_at: first_seen,
        suspected_count: watch.suspected_count + 1,
        next_check_at: next_confirmation_at(first_seen, now, jitter)
      }

      {:ok, maybe_update_current_duration(attrs, watch, observation), nil}
    end
  end

  defp success_attributes(watch, observation, now, jitter) do
    attrs =
      if is_nil(observation.duration_seconds) or observation.livestream do
        %{
          last_observed_at: now,
          last_error_at: now,
          next_check_at: DateTime.add(now, @observation_min_backoff_seconds + jitter, :second)
        }
      else
        %{
          last_observed_at: now,
          last_success_at: now,
          last_error_at: nil,
          error_count: 0,
          next_check_at: DateTime.add(now, @observation_success_seconds + jitter, :second)
        }
      end

    attrs =
      case Observation.current_visibility(observation) do
        nil -> attrs
        visibility -> Map.merge(attrs, %{current_visibility: visibility, observed_visibility: visibility})
      end

    attrs
    |> maybe_update_current_duration(watch, observation)
    |> fill_immutable_baseline(watch, observation)
    |> clear_unconfirmed_suspicion(watch)
  end

  defp maybe_update_current_duration(attrs, _watch, %{duration_seconds: duration, livestream: live})
       when is_integer(duration) and live != true,
       do: Map.put(attrs, :current_upstream_duration_seconds, duration)

  defp maybe_update_current_duration(attrs, _watch, _observation), do: attrs

  # The baseline is filled once from a trusted remote observation, never from
  # the locally processed file duration, and never reset by a later check.
  defp fill_immutable_baseline(attrs, watch, observation) do
    attrs =
      if is_nil(watch.baseline_upstream_duration_seconds) and is_integer(observation.duration_seconds) and
           not observation.livestream do
        Map.put(attrs, :baseline_upstream_duration_seconds, observation.duration_seconds)
      else
        attrs
      end

    case {watch.baseline_visibility, Observation.current_visibility(observation)} do
      {nil, visibility} when is_binary(visibility) -> Map.put(attrs, :baseline_visibility, visibility)
      _ -> attrs
    end
  end

  defp clear_unconfirmed_suspicion(attrs, %Watch{confirmed_state: "suspected"} = watch) do
    attrs
    |> Map.merge(%{
      confirmed_state: if(watch.confirmed_change_at, do: "confirmed", else: "unchanged"),
      suspected_kind: nil,
      suspected_value: nil,
      suspected_first_seen_at: nil,
      suspected_count: 0
    })
    |> then(fn attrs -> if watch.confirmed_change_at, do: attrs, else: maybe_clear_watcher_hold(attrs, watch) end)
  end

  defp clear_unconfirmed_suspicion(attrs, _watch), do: attrs

  defp maybe_clear_watcher_hold(attrs, %Watch{hold_reason: reason}) do
    if is_binary(reason) and String.starts_with?(reason, "watch change:") do
      Map.merge(attrs, %{hold_reason: nil, hold_at: nil})
    else
      attrs
    end
  end

  defp compatible_evidence?(%Watch{suspected_kind: "duration", suspected_value: value}, new_value) do
    case Integer.parse(value || "") do
      {previous, ""} when is_integer(new_value) -> abs(previous - new_value) <= 2
      _ -> false
    end
  end

  defp compatible_evidence?(watch, new_value), do: watch.suspected_value == to_string(new_value)

  defp build_event_attributes(kind, old_value, new_value, observed_at) do
    %{
      kind: kind,
      fingerprint: Observation.fingerprint(kind, old_value, new_value),
      old_value: stringify(old_value),
      new_value: stringify(new_value),
      observed_at: observed_at
    }
  end

  defp persist_observation(watch, attrs, event_attrs) do
    result =
      Repo.transaction(fn ->
        query =
          from w in Watch,
            where: w.id == ^watch.id and w.observation_version == ^watch.observation_version

        {affected, _} = Repo.update_all(query, set: Map.to_list(attrs), inc: [observation_version: 1])

        if affected != 1 do
          Repo.rollback(:stale_observation)
        end

        event =
          case event_attrs do
            nil ->
              nil

            attrs ->
              case record_event(
                     watch,
                     attrs.kind,
                     attrs.fingerprint <> ":transition:#{watch.observation_version + 1}",
                     Map.take(attrs, [:observed_at, :old_value, :new_value])
                   ) do
                {:ok, :duplicate} ->
                  nil

                {:ok, event} ->
                  case Oban.insert(NotificationWorker.new(%{"id" => event.id})) do
                    {:ok, _job} -> event
                    {:error, reason} -> Repo.rollback(reason)
                  end

                {:error, reason} ->
                  Repo.rollback(reason)
              end
          end

        {Repo.get!(Watch, watch.id), event}
      end)

    case result do
      {:ok, {updated, event}} ->
        {:ok, %{watch: updated, event: event}}

      error ->
        error
    end
  end

  defp next_confirmation_at(first_seen, now, jitter) do
    target = DateTime.add(first_seen, @observation_confirmation_seconds, :second)

    if DateTime.compare(target, now) == :gt do
      DateTime.add(target, jitter, :second)
    else
      DateTime.add(now, 60 + jitter, :second)
    end
  end

  defp observation_backoff(error_count) do
    exponent = min(max(error_count - 1, 0), 10)
    min(@observation_max_backoff_seconds, @observation_min_backoff_seconds * Integer.pow(2, exponent))
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp update_watch(%Watch{} = watch, attrs) do
    watch
    |> Watch.changeset(attrs)
    |> Repo.update()
  end

  defp recover_failed_publication(%Watch{} = watch) do
    update_archive_state(watch, fn _current ->
      case OriginalArchive.verify_relative(OriginalArchive.relative_manifest_path(watch.id), watch_id: watch.id) do
        {:ok, manifest} ->
          if first_archive_matches_approved?(watch, manifest) do
            %{
              archive_state: "published",
              original_manifest_path: OriginalArchive.relative_manifest_path(watch.id),
              operation_id: nil
            }
          else
            %{archive_state: "needs_recovery"}
          end

        _ ->
          state =
            if File.lstat(OriginalArchive.archive_directory(watch.id)) == {:error, :enoent},
              do: "none",
              else: "preparing"

          %{archive_state: state}
      end
    end)
  end

  defp update_archive_state(%Watch{} = watch, attrs) do
    Repo.transaction(fn ->
      query =
        from w in Watch,
          where:
            w.id == ^watch.id and w.lease_generation == ^watch.lease_generation and
              w.archive_state == ^watch.archive_state and is_nil(w.released_at)

      query =
        if watch.operation_id,
          do: where(query, [w], w.operation_id == ^watch.operation_id),
          else: where(query, [w], is_nil(w.operation_id))

      query =
        if watch.lease_owner,
          do: where(query, [w], w.lease_owner == ^watch.lease_owner),
          else: where(query, [w], is_nil(w.lease_owner))

      case Repo.update_all(query, set: [updated_at: utc_now()]) do
        {1, _} ->
          {:ok, current} = locked_watch(watch.id)

          case update_watch(current, attrs.(current)) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        _ ->
          Repo.rollback(:lost_lease)
      end
    end)
  end

  defp ensure_observation_unchanged(%Lease{} = lease) do
    watch = Repo.get!(Watch, lease.watch_id)

    if watch.observation_version == lease.observation_version and lease_current?(lease) do
      :ok
    else
      {:error, :watch_observation_changed}
    end
  end

  defp recheck_before_commit(%Lease{} = lease, %Watch{} = _archived) do
    with :ok <- renew_lease(lease),
         %Watch{} = watch <- Repo.get!(Watch, lease.watch_id),
         true <- watch.lease_owner == lease.owner and watch.lease_generation == lease.generation,
         true <- watch.observation_version == lease.observation_version,
         true <- replacement_eligible?(watch),
         true <- watch.archive_state == "published",
         {:ok, _manifest} <- verify_archive(watch) do
      :ok
    else
      false -> {:error, :watch_hold}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_watch(%Watch{} = snapshot) do
    action =
      Repo.transaction(fn ->
        now = utc_now()

        query =
          from w in Watch,
            where:
              w.id == ^snapshot.id and w.lease_generation == ^snapshot.lease_generation and
                (is_nil(w.lease_expires_at) or w.lease_expires_at <= ^now)

        case Repo.update_all(query, set: [updated_at: now]) do
          {1, _} ->
            {:ok, watch} = locked_watch(snapshot.id)
            action = recover_watch_action(watch)
            clear_expired_lease(watch)
            action

          _ ->
            :lease_busy
        end
      end)

    result =
      case action do
        {:ok, result} -> result
        {:error, _} -> :needs_recovery
      end

    %{watch_id: snapshot.id, action: result}
  end

  defp recover_watch_action(%Watch{archive_state: "preparing"} = watch) do
    manifest_path = watch.original_manifest_path || OriginalArchive.relative_manifest_path(watch.id)

    case OriginalArchive.verify_relative(manifest_path, watch_id: watch.id) do
      {:ok, manifest} ->
        if first_archive_matches_approved?(watch, manifest) do
          {:ok, _} =
            update_watch(watch, %{
              archive_state: "published",
              original_manifest_path: manifest_path,
              operation_id: nil
            })

          :published
        else
          {:ok, _} = update_watch(watch, %{archive_state: "needs_recovery"})
          :needs_recovery
        end

      {:error, _reason} ->
        directory = OriginalArchive.archive_directory(watch.id)

        cond do
          File.lstat(directory) == {:error, :enoent} ->
            _ = OriginalArchive.cleanup_temporary(watch.id)
            {:ok, _} = update_watch(watch, %{archive_state: "none", operation_id: nil})
            :unarchived

          watch.operation_id && OriginalArchive.clear_empty_reservation(watch.id) == :ok ->
            {:ok, _} = update_watch(watch, %{archive_state: "none", operation_id: nil})
            :unarchived

          true ->
            {:ok, _} = update_watch(watch, %{archive_state: "needs_recovery"})
            :needs_recovery
        end
    end
  end

  defp recover_watch_action(%Watch{}), do: :expired_lease

  defp clear_expired_lease(%Watch{} = watch) do
    if watch.lease_owner do
      query =
        from w in Watch,
          where:
            w.id == ^watch.id and w.lease_owner == ^watch.lease_owner and
              w.lease_generation == ^watch.lease_generation and
              (is_nil(w.lease_expires_at) or w.lease_expires_at <= ^utc_now())

      Repo.update_all(query, set: [lease_owner: nil, lease_expires_at: nil, operation_kind: nil])
    end

    :ok
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # A conditional UPDATE is the SQLite write reservation and the PostgreSQL
  # row gate: it only succeeds for the live owner and generation, and it takes
  # the row write lock for the rest of the transaction on both adapters.
  defp reserve_for_commit(%Lease{} = lease) do
    now = utc_now()
    expires_at = DateTime.add(now, @lease_seconds, :second)

    query =
      from w in Watch,
        where:
          w.id == ^lease.watch_id and w.lease_owner == ^lease.owner and
            w.lease_generation == ^lease.generation and not is_nil(w.lease_expires_at) and
            w.lease_expires_at > ^now

    case Repo.update_all(query, set: [lease_expires_at: expires_at]) do
      {1, _} -> :ok
      _ -> {:error, :lost_lease}
    end
  end

  defp locked_watch(watch_id) do
    query = from w in Watch, where: w.id == ^watch_id

    watch =
      if Pinchflat.Database.postgres?() do
        Repo.one(from w in query, lock: "FOR UPDATE")
      else
        Repo.one(query)
      end

    if watch, do: {:ok, watch}, else: {:error, :watch_missing}
  end

  defp verify_fence(%Lease{} = lease) do
    with true <- destructive_enabled?(),
         {:ok, watch} <- locked_watch(lease.watch_id),
         true <- watch.lease_owner == lease.owner and watch.lease_generation == lease.generation,
         true <- watch.observation_version == lease.observation_version,
         true <- replacement_eligible?(watch),
         true <- watch.archive_state == "published",
         {:ok, manifest} <- verify_archive(watch) do
      {:ok, manifest}
    else
      false -> {:error, :watch_hold}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_intent(%Lease{} = lease, %Watch{} = watch, %MediaItem{} = media_item, source_map, operation_id) do
    with {:ok, %{entries: entries}} <- OriginalArchive.archive_entries(media_item),
         {:ok, active} <- fingerprint_entries(entries, operation_id),
         :ok <- stash_stale_backups(active, watch.id, operation_id),
         :ok <- ensure_active_matches_approved(active, watch),
         {:ok, staged} <- fingerprint_staged(source_map) do
      ReplacementIntent.publish(watch.id, %{
        "operation_id" => operation_id,
        "created_at" => DateTime.to_iso8601(utc_now()),
        "phase" => "prepared",
        "media_item_id" => media_item.id,
        "media_item_uuid" => media_item.uuid,
        "archive_manifest_path" => watch.original_manifest_path || OriginalArchive.relative_manifest_path(watch.id),
        "lease" => %{
          "owner" => lease.owner,
          "generation" => lease.generation,
          "observation_version" => lease.observation_version
        },
        "active" => active,
        "staged" => staged
      })
    end
  end

  defp fingerprint_entries(entries, operation_id) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case ReplacementIntent.fingerprint(entry.source) do
        {:ok, %{sha256: checksum, size: size}} ->
          path = Path.expand(entry.source)

          {:cont,
           {:ok,
            [
              %{
                "role" => entry.role,
                "path" => path,
                "backup" => ReplacementIntent.backup_path(path, operation_id),
                "sha256" => checksum,
                "size" => size
              }
              | acc
            ]}}

        {:error, reason} ->
          {:halt, {:error, {:active_fingerprint_failed, entry.role, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # A backup from an earlier commit-cleanup failure duplicates the archive, so
  # it is quarantined rather than deleted or allowed to block this replacement.
  defp stash_stale_backups(active, watch_id, operation_id) do
    stale =
      active
      |> Enum.map(& &1["backup"])
      |> Enum.filter(fn path ->
        is_binary(path) and match?({:ok, %{type: :regular}}, File.lstat(path))
      end)

    case stale do
      [] ->
        :ok

      paths ->
        case ReplacementIntent.quarantine(watch_id, operation_id, paths) do
          {:ok, _moved} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp pre_images(intent) do
    intent
    |> Map.get("active", [])
    |> Enum.filter(&is_binary(&1["backup"]))
    |> Map.new(fn entry -> {entry["path"], entry["backup"]} end)
  end

  defp fingerprint_staged(source_map) do
    source_map
    |> Enum.reduce_while({:ok, []}, fn {source, destination}, {:ok, acc} ->
      case ReplacementIntent.fingerprint(source) do
        {:ok, %{sha256: checksum, size: size}} ->
          {:cont,
           {:ok,
            [
              %{
                "staged_path" => Path.expand(source),
                "destination" => Path.expand(destination),
                "sha256" => checksum,
                "size" => size
              }
              | acc
            ]}}

        {:error, reason} ->
          {:halt, {:error, {:staged_fingerprint_failed, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp ensure_active_matches_approved(_active, %{approved_active_files: %{"first" => first}})
       when not is_map(first),
       do: {:error, :active_file_unverifiable}

  defp ensure_active_matches_approved(_active, %{approved_active_files: %{"first" => first}})
       when map_size(first) == 0,
       do: {:error, :active_file_unverifiable}

  defp ensure_active_matches_approved(_active, %{approved_active_files: nil}),
    do: {:error, :active_file_unverifiable}

  defp ensure_active_matches_approved(_active, %{approved_active_files: approved})
       when not is_map_key(approved, "first"),
       do: {:error, :active_file_unverifiable}

  defp ensure_active_matches_approved(active, watch) do
    actual =
      active
      |> Enum.with_index()
      |> Map.new(fn {entry, index} ->
        {Integer.to_string(index), Map.take(entry, ["role", "path", "sha256", "size"])}
      end)

    if map_size(actual) == length(active) and actual == Map.delete(watch.approved_active_files, "first"),
      do: :ok,
      else: {:error, :active_file_changed}
  end

  defp ensure_item_matches_approved(watch, item) do
    with {:ok, %{entries: entries}} <- OriginalArchive.archive_entries(Repo.preload(item, :metadata)),
         {:ok, active} <- fingerprint_entries(entries, watch.operation_id || Ecto.UUID.generate()) do
      ensure_active_matches_approved(active, watch)
    end
  end

  defp first_archive_matches_approved?(%{approved_active_files: %{"first" => approved}}, manifest)
       when is_map(approved) and map_size(approved) > 0 do
    files = manifest["files"] || []

    if Enum.all?(approved, fn {index, file} -> is_binary(index) and is_map(file) end) do
      actual =
        files
        |> Enum.with_index()
        |> Map.new(fn {file, index} ->
          {Integer.to_string(index), Map.take(file, ["role", "sha256", "size"])}
        end)

      expected = Map.new(approved, fn {index, file} -> {index, Map.take(file, ["role", "sha256", "size"])} end)
      map_size(actual) == length(files) and actual == expected
    else
      false
    end
  end

  defp first_archive_matches_approved?(_watch, _manifest), do: false

  defp invoke_transfer(transfer_fun, pre_images) do
    case transfer_fun.(pre_images) do
      {:ok, transferred_json} when is_map(transferred_json) -> {:ok, transferred_json}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_transfer_result, other}}
    end
  rescue
    error -> {:error, {:transfer_raised, Exception.message(error)}}
  end

  defp verify_transferred(intent, transferred_json) do
    staged = intent["staged"] || []
    destinations = Enum.map(staged, & &1["destination"])

    with true <- is_binary(transferred_json["filepath"]),
         true <- transferred_json["filepath"] in destinations,
         :ok <- verify_staged_files(staged) do
      :ok
    else
      false -> {:error, :unexpected_media_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_staged_files(staged) do
    Enum.reduce_while(staged, :ok, fn entry, :ok ->
      destination = entry["destination"]
      expected = entry["sha256"]
      expected_size = entry["size"]

      case ReplacementIntent.fingerprint(destination) do
        {:ok, %{sha256: ^expected, size: ^expected_size}} ->
          {:cont, :ok}

        {:ok, %{sha256: ^expected}} ->
          {:halt, {:error, :transferred_size_mismatch}}

        {:ok, _other} ->
          {:halt, {:error, :transferred_checksum_mismatch}}

        {:error, reason} ->
          {:halt, {:error, {:transferred_file_missing, reason}}}
      end
    end)
  end

  defp invoke_update(update_fun, transferred_json) do
    case update_fun.(transferred_json) do
      {:ok, %MediaItem{} = updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_update_result, other}}
    end
  rescue
    error -> {:error, {:update_raised, Exception.message(error)}}
  end

  defp backup_postprocessing_files(intent) do
    intent["active"]
    |> Enum.filter(&(&1["role"] in ["internal-metadata", "internal-thumbnail", "nfo"]))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      backup = entry["backup"]
      expected = %{sha256: entry["sha256"], size: entry["size"]}

      cond do
        ReplacementIntent.fingerprint(backup) == {:ok, expected} ->
          {:cont, :ok}

        File.lstat(backup) != {:error, :enoent} ->
          {:halt, {:error, :pre_image_backup_changed}}

        ReplacementIntent.fingerprint(entry["path"]) != {:ok, expected} ->
          {:halt, {:error, :active_file_changed}}

        true ->
          case File.rename(entry["path"], backup) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp approved_active_files(updated, intent, transferred_json) do
    with {:ok, %{entries: entries}} <- OriginalArchive.archive_entries(updated) do
      staged = Map.new(intent["staged"], &{&1["destination"], &1})
      previous = Map.new(intent["active"], &{&1["path"], &1})

      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {entry, index}, {:ok, acc} ->
        path = Path.expand(entry.source)
        expected = Map.get(staged, path) || Map.get(previous, path)

        case ReplacementIntent.fingerprint(path) do
          {:ok, %{sha256: hash, size: size}} ->
            if match?(%{"sha256" => ^hash, "size" => ^size}, expected) or
                 generated_postprocessing_file?(entry, updated, transferred_json) do
              approved = %{"role" => entry.role, "path" => path, "sha256" => hash, "size" => size}
              {:cont, {:ok, Map.put(acc, Integer.to_string(index), approved)}}
            else
              {:halt, {:error, :active_file_changed}}
            end

          _ ->
            {:halt, {:error, :active_file_changed}}
        end
      end)
    end
  end

  defp generated_postprocessing_file?(%{role: "internal-metadata", source: path}, updated, json) do
    Path.expand(path) == Path.join(MetadataFileHelpers.metadata_directory_for(updated), "metadata.json.gz") and
      MetadataFileHelpers.read_compressed_metadata(path) == {:ok, json}
  end

  defp generated_postprocessing_file?(%{role: "internal-thumbnail", source: path}, updated, _json) do
    Path.expand(path) == Path.join(MetadataFileHelpers.metadata_directory_for(updated), "thumbnail.jpg")
  end

  defp generated_postprocessing_file?(%{role: "nfo", source: path}, updated, _json) do
    Path.expand(path) == Path.rootname(Path.expand(updated.media_filepath)) <> ".nfo"
  end

  defp generated_postprocessing_file?(_entry, _updated, _json), do: false

  defp mark_committed(%Lease{} = lease, operation_id, approved, watch) do
    query =
      from w in Watch,
        where: w.id == ^lease.watch_id and w.lease_owner == ^lease.owner and w.lease_generation == ^lease.generation

    case Repo.update_all(query,
           set: [
             operation_id: operation_id,
             approved_active_files: Map.put(approved, "first", watch.approved_active_files["first"]),
             lease_owner: nil,
             lease_expires_at: nil,
             operation_kind: nil
           ]
         ) do
      {1, _} -> :ok
      _ -> {:error, :lost_lease}
    end
  end

  defp recover_failed_replacement(%Lease{} = lease, operation_id) do
    result =
      Repo.transaction(fn ->
        query =
          from w in Watch,
            where:
              w.id == ^lease.watch_id and w.lease_owner == ^lease.owner and
                w.lease_generation == ^lease.generation and w.operation_kind == "replace" and
                is_nil(w.released_at)

        case Repo.update_all(query, set: [updated_at: utc_now()]) do
          {1, _} ->
            {:ok, _watch} = locked_watch(lease.watch_id)

            case ReplacementIntent.read(lease.watch_id) do
              {:ok,
               %{
                 "operation_id" => ^operation_id,
                 "lease" => %{"owner" => owner, "generation" => generation}
               } = intent}
              when owner == lease.owner and generation == lease.generation ->
                with :ok <- ReplacementIntent.restore(intent),
                     :ok <- ReplacementIntent.clear(lease.watch_id, operation_id) do
                  :ok
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, :not_pending} ->
                :ok

              _ ->
                Repo.rollback(:operation_mismatch)
            end

          _ ->
            case ReplacementIntent.read(lease.watch_id) do
              {:error, :not_pending} -> :ok
              _ -> Repo.rollback(:lost_lease)
            end
        end
      end)

    case result do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        Logger.error("watched replacement recovery failed for watch ##{lease.watch_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp recover_pending_intents(limit) do
    ReplacementIntent.pending_watch_ids(limit)
    |> Enum.map(fn watch_id ->
      action =
        case recover_pending_intent(watch_id) do
          {:ok, action} -> action
          {:error, _reason} -> :needs_recovery
        end

      %{watch_id: watch_id, action: action}
    end)
  end

  defp recover_pending_intent_for(watch_id) do
    if ReplacementIntent.pending?(watch_id) do
      case recover_pending_intent(watch_id) do
        {:ok, _action} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp recover_pending_intent(watch_id) do
    Repo.transaction(fn ->
      Repo.update_all(from(w in Watch, where: w.id == ^watch_id), set: [updated_at: utc_now()])

      with {:ok, watch} <- locked_watch(watch_id),
           {:ok, intent} <- ReplacementIntent.read(watch_id) do
        cond do
          not is_nil(watch.lease_owner) and not is_nil(watch.lease_expires_at) and
              DateTime.compare(watch.lease_expires_at, utc_now()) == :gt ->
            Repo.rollback(:lease_busy)

          committed_intent?(watch, intent) ->
            :ok = ReplacementIntent.clear(watch_id, intent["operation_id"])
            :commit_confirmed

          true ->
            case ReplacementIntent.restore(intent) do
              :ok ->
                :ok = ReplacementIntent.clear(watch_id, intent["operation_id"])
                clear_expired_lease(watch)
                :restored

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      else
        {:error, :not_pending} -> :nothing_pending
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, action} -> {:ok, action}
      error -> error
    end
  end

  # The watch row records the committed replacement operation under the same
  # reservation that wrote the media item, so it distinguishes a committed
  # transfer from an interrupted one even after a crash.
  defp committed_intent?(%Watch{} = watch, intent) do
    watch.operation_id == intent["operation_id"] and is_nil(watch.lease_owner)
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp effective_watch_window_days_for_source(nil), do: 0

  defp effective_watch_window_days_for_source(%Source{} = source) do
    source = Repo.preload(source, :media_profile)
    Source.effective_watch_window_days(source)
  end

  @doc """
  Returns the watch for a media item, if any.
  """
  def get_watch_for_media_item(media_item_id) do
    Repo.get_by(Watch, media_item_id: media_item_id)
  end

  @doc """
  Returns true when the media item has a watch row.
  """
  def watched?(media_item_id) do
    Repo.exists?(
      from watch in Watch,
        where:
          watch.media_item_id == ^media_item_id and
            (is_nil(watch.released_at) or watch.archive_state != "none")
    )
  end

  defp released?(watch), do: not is_nil(watch.released_at) and watch.archive_state == "none"

  @doc "Checks for watches whose originals would be orphaned by source/profile deletion."
  def deletion_blocked?(scope) do
    query =
      from watch in Watch,
        join: item in MediaItem,
        on: item.id == watch.media_item_id,
        join: source in Source,
        on: source.id == item.source_id,
        where: is_nil(watch.released_at) or watch.archive_state != "none"

    query =
      case scope do
        %Source{id: id} -> from [watch, item, source] in query, where: source.id == ^id
        %MediaProfile{id: id} -> from [watch, item, source] in query, where: source.media_profile_id == ^id
      end

    Repo.exists?(query)
  end

  @doc "Issues short-lived, version- and archive-bound consent for the protected confirmation page."
  def release_confirmation(%Watch{released_at: nil} = watch) do
    with {:ok, digest} <- release_archive_digest(watch) do
      data =
        {watch.id, watch.media_item_uuid, watch.observation_version, watch.lease_generation,
         watch.original_manifest_path, digest}

      {:ok, Phoenix.Token.sign(PinchflatWeb.Endpoint, "end-media-watch", data)}
    end
  end

  def release_confirmation(_watch), do: {:error, :already_released}

  defp release_archive_digest(%Watch{archive_state: "none", original_manifest_path: nil} = watch) do
    if File.lstat(OriginalArchive.archive_directory(watch.id)) == {:error, :enoent},
      do: {:ok, "none"},
      else: {:error, :archive_requires_recovery}
  end

  defp release_archive_digest(%Watch{archive_state: "published"} = watch),
    do: OriginalArchive.manifest_digest(watch)

  defp release_archive_digest(_watch), do: {:error, :archive_requires_recovery}

  @doc "Ends protection and explicitly deletes only the saved original. Current files and manual flags are preserved."
  def release_watch(%MediaItem{} = item, token) when is_binary(token) do
    with {:ok, {id, uuid, version, generation, path, digest}} <-
           Phoenix.Token.verify(PinchflatWeb.Endpoint, "end-media-watch", token, max_age: 600),
         %Watch{
           id: ^id,
           media_item_uuid: ^uuid,
           observation_version: ^version,
           lease_generation: ^generation,
           original_manifest_path: ^path,
           released_at: nil
         } = watch <- get_watch_for_media_item(item.id),
         true <- destructive_enabled?(),
         false <- Pinchflat.LegacyMigration.legacy_migration_pending?(),
         :ok <- recover_pending_intent_for(watch.id),
         {:ok, lease} <- claim_lease(item.id, "release_watch") do
      result =
        Repo.transaction(fn ->
          with :ok <- reserve_for_commit(lease),
               true <- lease.generation == generation + 1,
               {:ok, current} <- locked_watch(watch.id),
               true <- current.observation_version == version and is_nil(current.released_at),
               {:ok, ^digest} <- release_archive_digest(current),
               :ok <- verify_release_archive(current),
               :ok <- reserve_for_commit(lease) do
            current
            |> Ecto.Changeset.change(
              released_at: utc_now(),
              release_manifest_sha256: digest,
              next_check_at: nil,
              hold_reason: nil,
              hold_at: nil,
              observation_version: version + 1,
              operation_kind: "delete_original",
              operation_id: Ecto.UUID.generate(),
              lease_owner: nil,
              lease_expires_at: nil
            )
            |> Repo.update!()
          else
            _ -> Repo.rollback(:stale_confirmation)
          end
        end)

      case result do
        {:ok, released} ->
          finish_original_deletion(released.id)

        error ->
          release_lease(lease)
          error
      end
    else
      _ -> {:error, :stale_confirmation}
    end
  end

  def release_watch(_item, _token), do: {:error, :stale_confirmation}

  defp verify_release_archive(%Watch{archive_state: "none"}), do: :ok

  defp verify_release_archive(watch) do
    case verify_archive(watch) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Serializes watched active-file deletion with replacement and explicit archive release."
  def with_deletion_fence(%MediaItem{} = item, fun) do
    case get_watch_for_media_item(item.id) do
      nil ->
        Repo.transaction(fn ->
          Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [updated_at: utc_now()])

          case {Repo.get(MediaItem, item.id), get_watch_for_media_item(item.id)} do
            {%MediaItem{} = fresh, nil} ->
              case fun.(fresh) do
                {:ok, result} -> result
                {:error, reason} -> Repo.rollback(reason)
              end

            _ ->
              Repo.rollback(:watch_hold)
          end
        end)

      %Watch{released_at: released, archive_state: "none"} when not is_nil(released) ->
        fun.(item)

      %Watch{released_at: released} when not is_nil(released) ->
        {:error, :watch_hold}

      %Watch{} ->
        case claim_lease(item.id, "delete_active") do
          {:ok, lease} ->
            try do
              Repo.transaction(fn ->
                with :ok <- reserve_for_commit(lease),
                     :ok <- ensure_observation_unchanged(lease),
                     %MediaItem{} = fresh <- Repo.get(MediaItem, item.id),
                     {:ok, result} <- fun.(fresh) do
                  result
                else
                  {:error, reason} -> Repo.rollback(reason)
                  _ -> Repo.rollback(:not_found)
                end
              end)
            after
              release_lease(lease)
            end

          {:error, _} ->
            {:error, :watch_hold}
        end
    end
  end

  defp finish_original_deletion(id) do
    Repo.transaction(fn ->
      # Reserve before filesystem work on both adapters. A second recovery worker
      # must wait and re-read the durable intent; it cannot delete concurrently.
      Repo.update_all(from(w in Watch, where: w.id == ^id), set: [updated_at: utc_now()])
      {:ok, watch} = locked_watch(id)

      cond do
        watch.operation_kind != "delete_original" or is_nil(watch.released_at) ->
          Repo.rollback(:release_not_pending)

        watch.archive_state == "none" ->
          watch |> Ecto.Changeset.change(operation_kind: nil, operation_id: nil) |> Repo.update!()

        true ->
          case OriginalArchive.delete_released(watch) do
            :ok ->
              watch
              |> Ecto.Changeset.change(
                archive_state: "none",
                original_manifest_path: nil,
                operation_kind: nil,
                operation_id: nil,
                release_manifest_sha256: nil
              )
              |> Repo.update!()

            {:error, reason} ->
              Repo.rollback({:original_deletion_pending, reason})
          end
      end
    end)
  end

  @doc """
  Whether a download may obtain a new active copy for this media item.

  A watched item is blocked while the preservation gate is unapproved or while
  the watch is held or confirmed changed. This runs before the download starts
  so a blocked watch does not waste bandwidth and cannot overwrite the original.
  """
  def replacement_blocked?(media_item_id) do
    case get_watch_for_media_item(media_item_id) do
      nil ->
        false

      %Watch{} = watch ->
        not released?(watch) and (not destructive_enabled?() or not replacement_eligible?(watch))
    end
  end

  defp replacement_eligible?(%Watch{} = watch) do
    now = utc_now()
    item = watch.media_item_id && Repo.get(MediaItem, watch.media_item_id)

    is_nil(watch.released_at) and is_nil(watch.last_error_at) and not is_nil(watch.last_success_at) and
      DateTime.diff(now, watch.last_success_at, :second) <= @observation_success_seconds + @observation_jitter_seconds and
      DateTime.compare(watch.ends_at, now) == :gt and watch.confirmed_state == "unchanged" and
      is_nil(watch.hold_reason) and watch.archive_state != "needs_recovery" and
      not Pinchflat.LegacyMigration.legacy_migration_pending?() and
      not is_nil(item) and not item.prevent_download and not item.prevent_culling and
      effective_watch_window_days_for_source(Repo.preload(item, source: :media_profile).source) > 0
  end

  @doc """
  Whether destructive watched-file operations may run.

  The independent M2 safety review approved the fence, archive and recovery
  paths, so this is enabled by default now that a watch window can be set to a
  positive number of days. Set `:media_watch_destructive_enabled` to `false` to
  make watched replacements and active-file deletion fail closed again without
  disabling observation or saved-original verification.
  """
  def destructive_enabled? do
    Application.get_env(:pinchflat, :media_watch_destructive_enabled, true) != false
  end

  @doc """
  Claims a bounded lease for a watched file operation.

  The conditional UPDATE is the SQLite write reservation and the PostgreSQL
  row gate. Exactly one caller can win a generation; an expired owner cannot
  renew and must abandon staged work.

  Returns {:ok, %Lease{}} | {:error, :not_watched | :lease_busy}.
  """
  def claim_lease(media_item_id, operation_kind, opts \\ []) do
    case get_watch_for_media_item(media_item_id) do
      nil ->
        {:error, :not_watched}

      %Watch{} = watch ->
        now = utc_now()
        owner = Keyword.get(opts, :owner) || Ecto.UUID.generate()
        lease_seconds = Keyword.get(opts, :lease_seconds, @lease_seconds)
        expires_at = DateTime.add(now, lease_seconds, :second)

        query =
          from w in Watch,
            where:
              w.id == ^watch.id and is_nil(w.released_at) and
                (is_nil(w.lease_expires_at) or w.lease_expires_at <= ^now)

        {affected, _} =
          Repo.update_all(query,
            set: [lease_owner: owner, lease_expires_at: expires_at, operation_kind: operation_kind],
            inc: [lease_generation: 1]
          )

        if affected == 1 do
          updated = Repo.get!(Watch, watch.id)

          {:ok,
           %Lease{
             watch_id: updated.id,
             owner: owner,
             generation: updated.lease_generation,
             observation_version: updated.observation_version,
             expires_at: expires_at,
             operation_kind: operation_kind
           }}
        else
          {:error, :lease_busy}
        end
    end
  end

  @doc """
  Renews a live lease owned by the same generation.

  Returns :ok | {:error, :lost_lease}.
  """
  def renew_lease(%Lease{} = lease, opts \\ []) do
    now = utc_now()
    lease_seconds = Keyword.get(opts, :lease_seconds, @lease_seconds)
    expires_at = DateTime.add(now, lease_seconds, :second)

    query =
      from w in Watch,
        where:
          w.id == ^lease.watch_id and w.lease_owner == ^lease.owner and
            w.lease_generation == ^lease.generation and not is_nil(w.lease_expires_at) and
            w.lease_expires_at > ^now

    case Repo.update_all(query, set: [lease_expires_at: expires_at]) do
      {1, _} -> :ok
      _ -> {:error, :lost_lease}
    end
  end

  @doc """
  Returns true only for the same live owner and generation.
  """
  def lease_current?(%Lease{} = lease) do
    now = utc_now()

    Repo.exists?(
      from w in Watch,
        where:
          w.id == ^lease.watch_id and w.lease_owner == ^lease.owner and
            w.lease_generation == ^lease.generation and not is_nil(w.lease_expires_at) and
            w.lease_expires_at > ^now
    )
  end

  @doc """
  Releases a lease held by the same owner and generation. A superseded owner
  cannot clear a successor's lease.

  Returns :ok.
  """
  def release_lease(%Lease{} = lease) do
    query =
      from w in Watch,
        where: w.id == ^lease.watch_id and w.lease_owner == ^lease.owner and w.lease_generation == ^lease.generation

    Repo.update_all(query, set: [lease_owner: nil, lease_expires_at: nil, operation_kind: nil])
    :ok
  end

  @doc """
  Publishes the first original for a watch if it is not already published.

  Returns {:ok, %Watch{}} | {:error, term()}.
  """
  def archive_original(%Watch{} = watch, %MediaItem{} = media_item, opts \\ []) do
    watch = Repo.get!(Watch, watch.id)

    cond do
      not is_nil(watch.released_at) ->
        {:error, :watch_released}

      watch.archive_state == "published" ->
        with :ok <- ensure_item_matches_approved(watch, media_item),
             {:ok, _manifest} <- verify_archive(watch) do
          {:ok, watch}
        end

      true ->
        with true <- watch.archive_state in ["none", "needs_recovery"],
             :ok <- ensure_item_matches_approved(watch, media_item),
             {:ok, preparing} <-
               update_archive_state(watch, fn _current ->
                 %{archive_state: "preparing", operation_id: Ecto.UUID.generate()}
               end) do
          publish_original(preparing, media_item, opts)
        else
          false -> {:error, :archive_preparing}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp publish_original(preparing, media_item, opts) do
    case OriginalArchive.publish(preparing, media_item, opts) do
      {:ok, %{manifest_path: manifest_path, manifest: manifest}} ->
        if first_archive_matches_approved?(preparing, manifest) and
             ensure_item_matches_approved(preparing, media_item) == :ok do
          update_archive_state(preparing, fn _current ->
            %{archive_state: "published", original_manifest_path: manifest_path, operation_id: nil}
          end)
        else
          case recover_failed_publication(preparing) do
            {:ok, _} -> {:error, :active_file_changed}
            {:error, reason} -> {:error, {:archive_recovery_failed, :active_file_changed, reason}}
          end
        end

      {:error, reason} ->
        case recover_failed_publication(preparing) do
          {:ok, _} -> {:error, reason}
          {:error, recovery_reason} -> {:error, {:archive_recovery_failed, reason, recovery_reason}}
        end
    end
  end

  @doc """
  Verifies the published archive for a watch.

  Returns {:ok, map()} | {:error, term()}.
  """
  def verify_archive(%Watch{} = watch) do
    path = watch.original_manifest_path || OriginalArchive.relative_manifest_path(watch.id)

    with {:ok, manifest} <- OriginalArchive.verify_relative(path, watch_id: watch.id),
         true <- first_archive_matches_approved?(watch, manifest) do
      {:ok, manifest}
    else
      false -> {:error, :active_file_unverifiable}
      error -> error
    end
  end

  @doc """
  Prepares a watched replacement: claims the lease, publishes or verifies the
  original archive, and rechecks the fencing state immediately before the
  caller mutates active files.

  Returns {:ok, %Lease{} | :unwatched} | {:error, term()}.
  """
  def prepare_replacement(%MediaItem{} = media_item, opts \\ []) do
    case get_watch_for_media_item(media_item.id) do
      nil ->
        {:ok, :unwatched}

      %Watch{} = watch ->
        cond do
          released?(watch) ->
            {:ok, :unwatched}

          not destructive_enabled?() ->
            {:error, :watch_guard_unapproved}

          not replacement_eligible?(watch) ->
            {:error, :watch_hold}

          true ->
            with :ok <- recover_pending_intent_for(watch.id),
                 {:ok, lease} <- claim_lease(media_item.id, "replace", opts),
                 :ok <- ensure_observation_unchanged(lease),
                 {:ok, archived} <- archive_original(watch, media_item, opts),
                 :ok <- recheck_before_commit(lease, archived) do
              {:ok, lease}
            else
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  @doc """
  Commits a watched replacement inside one adapter-safe write reservation.

  The watch row is reserved first (conditional UPDATE, plus `SELECT FOR UPDATE`
  on PostgreSQL), the lease generation, observation version, policy and archive
  are re-verified under that reservation, and a durable intent journal is
  published before the first active file moves. The caller's transfer runs next;
  only after every destination re-hashes to the recorded staged checksum is the
  media item written and the lease cleared, still inside the same transaction.

  A failure at any point rolls the database back and restores the active files
  from the verified original archive. The journal is left in place when that
  restoration cannot be proven, so startup recovery retries instead of claiming
  success.

  Returns {:ok, MediaItem.t()} | {:error, term()}.
  """
  def commit_replacement(
        %Lease{} = lease,
        %MediaItem{} = media_item,
        %{source_map: source_map},
        transfer_fun,
        update_fun
      )
      when is_map(source_map) and is_function(transfer_fun, 1) and is_function(update_fun, 1) do
    if destructive_enabled?() do
      do_commit_replacement(lease, media_item, source_map, transfer_fun, update_fun)
    else
      {:error, :watch_guard_unapproved}
    end
  end

  defp do_commit_replacement(%Lease{} = lease, %MediaItem{} = media_item, source_map, transfer_fun, update_fun) do
    media_item = Repo.preload(media_item, [:metadata, source: :media_profile])
    operation_id = Ecto.UUID.generate()

    result =
      try do
        Repo.transaction(fn ->
          with :ok <- reserve_for_commit(lease),
               {:ok, watch} <- locked_watch(lease.watch_id),
               {:ok, _manifest} <- verify_fence(lease),
               {:ok, intent} <- publish_intent(lease, watch, media_item, source_map, operation_id),
               :ok <- ReplacementIntent.advance(intent, "transferring"),
               {:ok, transferred_json} <- invoke_transfer(transfer_fun, pre_images(intent)),
               :ok <- verify_transferred(intent, transferred_json),
               :ok <- reserve_for_commit(lease),
               {:ok, _manifest} <- verify_fence(lease),
               :ok <- backup_postprocessing_files(intent),
               {:ok, updated} <- invoke_update(update_fun, transferred_json),
               {:ok, approved} <- approved_active_files(updated, intent, transferred_json),
               :ok <- mark_committed(lease, operation_id, approved, watch) do
            {updated, intent}
          else
            {:error, reason} -> Repo.rollback(reason)
            other -> Repo.rollback({:unexpected_replacement_error, other})
          end
        end)
      rescue
        error ->
          Logger.error("watched replacement raised: #{Exception.message(error)}")
          {:error, {:replacement_raised, error}}
      end

    case result do
      {:ok, {updated, intent}} ->
        _ = ReplacementIntent.clear(intent["watch_id"], operation_id)
        _ = ReplacementIntent.clear_backups(intent)
        {:ok, updated}

      {:error, reason} ->
        case recover_failed_replacement(lease, operation_id) do
          :ok -> {:error, reason}
          {:error, recovery_reason} -> {:error, {:replacement_recovery_failed, reason, recovery_reason}}
        end
    end
  end

  @doc """
  Releases the replacement lease after the caller has completed its transfer.
  """
  def finish_replacement(%Lease{} = lease), do: release_lease(lease)

  @doc """
  Releases the replacement lease after a failed or aborted transfer.
  """
  def abort_replacement(%Lease{} = lease), do: release_lease(lease)

  @doc """
  Gate for deleting active files of a media item.

  Unwatched items keep existing behavior. A watched item requires the M2
  execution gate and a verified published original; otherwise the caller must
  not delete active files.

  Returns :ok | {:error, term()}.
  """
  def allow_active_file_deletion(%MediaItem{} = media_item) do
    case get_watch_for_media_item(media_item.id) do
      nil ->
        :ok

      %Watch{} = watch ->
        cond do
          released?(watch) ->
            :ok

          not is_nil(watch.released_at) ->
            {:error, :original_deletion_pending}

          not destructive_enabled?() ->
            {:error, :watch_guard_unapproved}

          ReplacementIntent.pending?(watch.id) ->
            {:error, :replacement_in_progress}

          watch.archive_state != "published" ->
            {:error, :watch_archive_required}

          true ->
            with :ok <- ensure_item_matches_approved(watch, media_item),
                 {:ok, _manifest} <- verify_archive(watch) do
              :ok
            end
        end
    end
  end

  @doc "Returns a watch by ID, or nil."
  def get_watch(id), do: Repo.get(Watch, id)

  @doc """
  Returns the public API representation of a watch. Internal lease and filesystem
  details stay out of API responses.
  """
  def to_api_map(%Watch{} = watch) do
    %{
      started_at: iso8601(watch.started_at),
      ends_at: iso8601(watch.ends_at),
      confirmed_state: watch.confirmed_state,
      current_visibility: watch.observed_visibility || watch.current_visibility,
      current_upstream_duration_seconds: watch.current_upstream_duration_seconds,
      suspected_kind: watch.suspected_kind,
      baseline_upstream_duration_seconds: watch.baseline_upstream_duration_seconds,
      last_success_at: iso8601(watch.last_success_at),
      last_error_at: iso8601(watch.last_error_at),
      hold_reason: watch.hold_reason,
      archive_state: watch.archive_state,
      released_at: iso8601(watch.released_at),
      saved_original_available:
        watch.archive_state == "published" and is_nil(watch.released_at) and
          match?({:ok, _summary}, OriginalArchive.summary(watch))
    }
  end

  @doc """
  Returns due watch IDs in bounded pages.

  Expired watches, watches for media that no longer exists and sources whose
  effective watch window is disabled are excluded here so a disabled feature
  does not keep enqueuing observation work.
  """
  def list_due_watch_ids(now \\ utc_now(), limit \\ 50) do
    Repo.all(
      from watch in Watch,
        join: item in MediaItem,
        on: item.id == watch.media_item_id,
        join: source in Source,
        on: source.id == item.source_id,
        join: profile in MediaProfile,
        on: profile.id == source.media_profile_id,
        where:
          not is_nil(watch.next_check_at) and watch.next_check_at <= ^now and
            watch.ends_at > ^now and is_nil(watch.released_at) and
            fragment("COALESCE(?, ?)", source.watch_window_days, profile.watch_window_days) > 0,
        order_by: [asc: watch.next_check_at, asc: watch.id],
        limit: ^limit,
        select: watch.id
    )
  end

  @doc """
  Rechecks whether an observation may run now.

  Returns :ok | {:skip, atom()}. The worker performs no external request when
  this returns a skip.
  """
  def observation_eligible?(%Watch{} = watch, now \\ nil) do
    now = now || utc_now()

    cond do
      not is_nil(watch.released_at) ->
        {:skip, :released}

      Pinchflat.LegacyMigration.legacy_migration_pending?() ->
        {:skip, :migration_hold}

      DateTime.compare(watch.ends_at, now) != :gt ->
        {:skip, :expired}

      is_nil(watch.media_item_id) ->
        {:skip, :media_item_missing}

      true ->
        item = Repo.get(MediaItem, watch.media_item_id)

        cond do
          is_nil(item) or is_nil(item.media_filepath) ->
            {:skip, :media_item_missing}

          effective_watch_window_days_for_source(Repo.preload(item, source: :media_profile).source) <= 0 ->
            {:skip, :disabled}

          true ->
            :ok
        end
    end
  end

  @doc """
  Applies a normalized observation to a watch.

  A suspected change immediately creates a watcher-owned hold. Confirmation
  needs a compatible observation at least 15 minutes after the first
  suspicion; only then is one durable event recorded. Unknown observations use
  exponential backoff and never clear a suspicion or change the baseline.

  Returns {:ok, %{watch: %Watch{}, event: %Event{} | nil}} | {:error, term()}.
  """
  def record_observation(watch_or_id, %Observation{} = observation, opts \\ []) do
    watch =
      case watch_or_id do
        %Watch{id: id} -> Repo.get(Watch, id)
        id when is_integer(id) -> Repo.get(Watch, id)
      end

    cond do
      is_nil(watch) or not is_nil(watch.released_at) ->
        {:error, :not_found}

      watch.last_observed_at && DateTime.compare(observation.observed_at, watch.last_observed_at) == :lt ->
        {:ok, %{watch: watch, event: nil}}

      true ->
        now = observation.observed_at
        jitter = Keyword.get(opts, :jitter_seconds, :rand.uniform(@observation_jitter_seconds))

        with {:ok, attrs, event_attrs} <- decide_observation(watch, observation, now, jitter) do
          persist_observation(watch, attrs, event_attrs)
        end
    end
  end

  @doc """
  Reconciles a bounded set of expired leases and interrupted archive
  publications, and resumes explicitly approved saved-original deletions.
  An archive without a durable release intent is never deleted. If no validated
  original was published, the watch stays unarchived instead of claiming success.

  Returns [%{watch_id: integer(), action: term()}].
  """
  def recover_pending(limit \\ @recovery_batch_size) do
    now = utc_now()

    watches =
      Repo.all(
        from w in Watch,
          where:
            (w.archive_state == "preparing" or not is_nil(w.lease_owner)) and
              (is_nil(w.lease_expires_at) or w.lease_expires_at <= ^now),
          order_by: [asc: w.id],
          limit: ^limit
      )

    released =
      Repo.all(
        from w in Watch,
          where:
            not is_nil(w.released_at) and
              w.operation_kind == "delete_original",
          order_by: w.id,
          limit: ^limit
      )

    Enum.map(released, fn watch ->
      %{watch_id: watch.id, action: finish_original_deletion(watch.id)}
    end) ++ Enum.map(watches, &recover_watch/1) ++ recover_pending_intents(limit)
  end

  @doc """
  Records a confirmed transition event, deduplicated by (watch, kind, fingerprint).
  """
  @spec record_event(Watch.t(), String.t(), String.t(), map()) ::
          {:ok, Event.t()} | {:ok, :duplicate} | {:error, term()}
  def record_event(%Watch{} = watch, kind, fingerprint, attrs \\ %{}) do
    base = %{
      media_watch_id: watch.id,
      kind: kind,
      fingerprint: fingerprint,
      observed_at: Map.get(attrs, :observed_at, DateTime.utc_now() |> DateTime.truncate(:second)),
      old_value: Map.get(attrs, :old_value),
      new_value: Map.get(attrs, :new_value),
      delivery_state: "pending"
    }

    %Event{}
    |> Event.changeset(base)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        {:ok, event}

      {:error, changeset} ->
        if unique_constraint_error?(changeset) do
          {:ok, :duplicate}
        else
          {:error, changeset}
        end
    end
  end

  @doc "Returns all confirmed transition events for a watch, newest first."
  @spec list_events(integer()) :: [Event.t()]
  def list_events(watch_id) when is_integer(watch_id) do
    Repo.all(
      from e in Event,
        where: e.media_watch_id == ^watch_id,
        order_by: [desc: e.observed_at, desc: e.id]
    )
  end

  def list_events(_watch_id), do: []

  defp availability_to_string(nil), do: nil
  defp availability_to_string(value), do: to_string(value)

  defp unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end
end
