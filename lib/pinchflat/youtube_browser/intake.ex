defmodule Pinchflat.YoutubeBrowser.Intake do
  @moduledoc """
  Guarded single-video download intake and channel subscription module.
  Enforces migration hold refusals, profile validation, duplicate prevention,
  and safe single-item queueing without forcing overwrites or subscribing to uploaders.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task
  alias Pinchflat.YoutubeBrowser.Status

  @active_job_states ["executing", "available", "scheduled", "retryable"]

  @media_download_workers [
    "Pinchflat.Downloading.MediaDownloadWorker",
    "Elixir.Pinchflat.Downloading.MediaDownloadWorker"
  ]

  @source_indexing_workers [
    "Pinchflat.SlowIndexing.MediaCollectionIndexingWorker",
    "Elixir.Pinchflat.SlowIndexing.MediaCollectionIndexingWorker",
    "Pinchflat.FastIndexing.FastIndexingWorker",
    "Elixir.Pinchflat.FastIndexing.FastIndexingWorker"
  ]

  @doc """
  Returns true if either the legacy migration review hold or the
  PostgreSQL database transfer hold is active.
  """
  def migration_hold_active? do
    Pinchflat.Database.PostgresMigration.pending?() or
      Pinchflat.LegacyMigration.legacy_migration_pending?()
  end

  @doc """
  Guarded single-video download intake.
  Accepts a video ID and media profile ID.
  Returns:
    - `{:ok, :queued}` — single item enqueued
    - `{:ok, :queued_paused}` — item enqueued into a paused queue
    - `{:ok, :indexing}` — single-video source created and indexing kicked off
    - `{:error, :migration_hold_active}` — rejected because migration review/transfer is in progress
    - `{:error, :invalid_profile}` — profile not found
    - `{:error, :invalid_video_id}` — malformed video ID
    - `{:error, :already_present}` — file is verified present in library
    - `{:error, :already_queued}` — already actively downloading or in queue
    - `{:error, :source_disabled}` — source is intentionally disabled/paused
    - `{:error, :source_downloads_disabled}` — source has download_media set to false
    - `{:error, :download_prevented}` — media item has prevent_download set
    - `{:error, :culled}` — media item was culled
    - `{:error, :unavailable}` — media item is unavailable
    - `{:error, :missing_file}` — file missing on disk; repair must be done explicitly
    - `{:error, :storage_unverified}` — storage is not verified regular media file
    - `{:error, :storage_inaccessible}` — storage is inaccessible
    - `{:error, :policy_ineligible}` — media item is ineligible under source/profile policies
    - `{:error, :ambiguous_copies}` — multiple copies exist under this profile
    - `{:error, any()}` — failed
  """
  def download_video(video_id, profile_id, opts \\ []) do
    cond do
      migration_hold_active?() ->
        {:error, :migration_hold_active}

      not is_integer(profile_id) ->
        {:error, :invalid_profile}

      true ->
        case validate_video_id(video_id) do
          {:ok, clean_id} ->
            case Repo.get(MediaProfile, profile_id) do
              nil ->
                {:error, :invalid_profile}

              _profile ->
                handle_download_for_valid_profile(clean_id, profile_id, opts)
            end

          error ->
            error
        end
    end
  end

  defp validate_video_id(video_id) when is_binary(video_id) do
    trimmed = String.trim(video_id)

    if trimmed != "" and byte_size(trimmed) <= 64 and Regex.match?(~r/^[a-zA-Z0-9_-]+$/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_video_id}
    end
  end

  defp validate_video_id(_), do: {:error, :invalid_video_id}

  defp handle_download_for_valid_profile(video_id, profile_id, opts) do
    # Check existing media items matching this video_id and profile_id
    matching_items =
      from(m in MediaItem,
        join: s in assoc(m, :source),
        where: m.media_id == ^video_id and s.media_profile_id == ^profile_id,
        preload: [source: s]
      )
      |> Repo.all()

    case matching_items do
      [] ->
        # No media item yet; check if a single-video source already exists or create one
        handle_new_video_source(video_id, profile_id, opts)

      [single_item] ->
        # Single existing media item found; queue ONLY this single item
        enqueue_existing_item(single_item, opts)

      _multiple_items ->
        # Multiple copies under this profile: require disambiguation
        {:error, :ambiguous_copies}
    end
  end

  defp enqueue_existing_item(%MediaItem{} = item, opts) do
    oban_name = Keyword.get(opts, :oban_name, Oban)
    item = Repo.preload(item, source: :media_profile)
    source = item.source

    cond do
      # 1. Source disabled
      source.enabled == false ->
        {:error, :source_disabled}

      # 2. Source downloads disabled
      source.download_media == false ->
        {:error, :source_downloads_disabled}

      # 3. Prevent download flag
      item.prevent_download == true ->
        {:error, :download_prevented}

      # 4. Culled
      not is_nil(item.culled_at) ->
        {:error, :culled}

      # 5. Unavailable
      not is_nil(item.unavailable_at) ->
        {:error, :unavailable}

      # 6. Saved path check: refusing unverified or missing storage from normal queueing
      is_binary(item.media_filepath) and item.media_filepath != "" ->
        case Status.check_file_state(item.media_filepath) do
          :verified_present -> {:error, :already_present}
          :missing -> {:error, :missing_file}
          :inaccessible -> {:error, :storage_inaccessible}
          _ -> {:error, :storage_unverified}
        end

      # 7. Media item eligibility under source/profile rules
      not Pinchflat.Media.pending_download?(item) ->
        {:error, :policy_ineligible}

      true ->
        # 8. Check active download jobs
        active_jobs =
          from(t in Task,
            join: j in assoc(t, :job),
            where:
              t.media_item_id == ^item.id and
                j.state in ^@active_job_states and
                j.worker in ^@media_download_workers,
            select: j.id
          )
          |> Repo.all()

        if active_jobs != [] do
          {:error, :already_queued}
        else
          # Kick off single item download without force
          case MediaDownloadWorker.kickoff_with_task(item, %{}, []) do
            {:ok, _task} ->
              if queue_paused?(:media_fetching, oban_name) do
                {:ok, :queued_paused}
              else
                {:ok, :queued}
              end

            {:error, :duplicate_job} ->
              {:error, :already_queued}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp handle_new_video_source(video_id, profile_id, opts) do
    # Check if single-video sources already exist for this video_id and profile
    existing_sources =
      from(s in Source,
        where:
          s.collection_type == :video and
            s.collection_id == ^video_id and
            s.media_profile_id == ^profile_id
      )
      |> Repo.all()

    case existing_sources do
      [] ->
        create_and_kickoff_single_video_source(video_id, profile_id, opts)

      [single_source] ->
        handle_single_video_source(single_source)

      _multiple_sources ->
        {:error, :ambiguous_copies}
    end
  end

  defp handle_single_video_source(%Source{} = source) do
    cond do
      source.enabled == false ->
        {:error, :source_disabled}

      source.download_media == false ->
        {:error, :source_downloads_disabled}

      true ->
        active_source_jobs =
          from(t in Task,
            join: j in assoc(t, :job),
            where:
              t.source_id == ^source.id and
                j.state in ^@active_job_states and
                j.worker in ^@source_indexing_workers,
            select: j.id
          )
          |> Repo.all()

        if active_source_jobs != [] do
          {:error, :already_queued}
        else
          case MediaCollectionIndexingWorker.kickoff_with_task(source) do
            {:ok, _task} -> {:ok, :indexing}
            {:error, :duplicate_job} -> {:error, :already_queued}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp create_and_kickoff_single_video_source(video_id, profile_id, opts) do
    source_name = Keyword.get(opts, :video_title) || "YouTube Video #{video_id}"

    source_attrs = %{
      collection_type: :video,
      source_type: :video,
      collection_id: video_id,
      collection_name: source_name,
      custom_name: source_name,
      original_url: "https://www.youtube.com/watch?v=#{video_id}",
      media_profile_id: profile_id,
      download_media: true,
      index_frequency_minutes: 0,
      fast_index: false,
      enabled: true
    }

    changeset =
      %Source{}
      |> Source.changeset(source_attrs, :pre_insert)

    transaction_result =
      try do
        Repo.transaction(fn ->
          if migration_hold_active?() do
            Repo.rollback(:migration_hold_active)
          end

          if is_nil(Repo.get(MediaProfile, profile_id)) do
            Repo.rollback(:invalid_profile)
          end

          case Repo.insert(changeset) do
            {:ok, source} ->
              case MediaCollectionIndexingWorker.kickoff_with_task(source) do
                {:ok, _task} ->
                  {:ok, :indexing}

                {:error, :duplicate_job} ->
                  {:ok, :indexing}

                {:error, reason} ->
                  Repo.rollback(reason)
              end

            {:error, %Ecto.Changeset{} = err_cs} ->
              if unique_constraint_conflict?(err_cs) do
                Repo.rollback(:race_conflict)
              else
                Repo.rollback(err_cs)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      rescue
        _ in [Exqlite.Error, Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
          {:error, :database_exception}
      end

    case transaction_result do
      {:ok, {:ok, :indexing}} ->
        {:ok, :indexing}

      {:error, :race_conflict} ->
        # Another tab/request won the race; re-verify state
        handle_new_video_source(video_id, profile_id, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Guarded explicit channel subscription intake.
  Accepts a channel ID, media profile ID, and optional attributes (such as `:channel_title`).
  Returns:
    - `{:ok, %Source{}}` — channel source created and initial indexing scheduled
    - `{:error, :migration_hold_active}` — rejected because migration review/transfer is in progress
    - `{:error, :invalid_profile}` — profile not found or invalid
    - `{:error, :invalid_channel_id}` — malformed channel ID
    - `{:error, {:already_tracked, %Source{}}}` — channel already exists under this profile (active or disabled)
    - `{:error, any()}` — failed
  """
  def subscribe_channel(channel_id, profile_id, opts \\ []) do
    cond do
      migration_hold_active?() ->
        {:error, :migration_hold_active}

      not is_integer(profile_id) ->
        {:error, :invalid_profile}

      true ->
        case validate_channel_id(channel_id) do
          {:ok, clean_id} ->
            case Repo.get(MediaProfile, profile_id) do
              nil ->
                {:error, :invalid_profile}

              _profile ->
                handle_channel_subscription(clean_id, profile_id, opts)
            end

          error ->
            error
        end
    end
  end

  defp validate_channel_id(channel_id) when is_binary(channel_id) do
    trimmed = String.trim(channel_id)

    if trimmed != "" and byte_size(trimmed) <= 64 and Regex.match?(~r/^[a-zA-Z0-9_@.-]+$/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_channel_id}
    end
  end

  defp validate_channel_id(_), do: {:error, :invalid_channel_id}

  defp handle_channel_subscription(channel_id, profile_id, opts) do
    existing_sources =
      from(s in Source,
        where:
          s.collection_type == :channel and
            s.collection_id == ^channel_id and
            s.media_profile_id == ^profile_id
      )
      |> Repo.all()

    case existing_sources do
      [] ->
        create_and_kickoff_channel_source(channel_id, profile_id, opts)

      [single_source] ->
        {:error, {:already_tracked, single_source}}

      _multiple_sources ->
        {:error, :ambiguous_copies}
    end
  end

  defp create_and_kickoff_channel_source(channel_id, profile_id, opts) do
    channel_name = Keyword.get(opts, :channel_title) || "YouTube Channel #{channel_id}"
    index_frequency_minutes = Keyword.get(opts, :index_frequency_minutes, 180)
    download_media = Keyword.get(opts, :download_media, true)
    download_cutoff_date = Keyword.get(opts, :download_cutoff_date, nil)

    source_attrs = %{
      collection_type: :channel,
      source_type: :channel,
      collection_id: channel_id,
      collection_name: channel_name,
      custom_name: channel_name,
      original_url: "https://www.youtube.com/channel/#{channel_id}",
      media_profile_id: profile_id,
      download_media: download_media,
      index_frequency_minutes: index_frequency_minutes,
      download_cutoff_date: download_cutoff_date,
      fast_index: false,
      enabled: true
    }

    changeset =
      %Source{}
      |> Source.changeset(source_attrs, :pre_insert)

    transaction_result =
      try do
        Repo.transaction(fn ->
          if migration_hold_active?() do
            Repo.rollback(:migration_hold_active)
          end

          if is_nil(Repo.get(MediaProfile, profile_id)) do
            Repo.rollback(:invalid_profile)
          end

          case Repo.insert(changeset) do
            {:ok, source} ->
              indexing_res =
                case MediaCollectionIndexingWorker.kickoff_with_task(source) do
                  {:ok, _task} -> :ok
                  {:error, :duplicate_job} -> :ok
                  {:error, reason} -> {:error, reason}
                end

              metadata_res =
                case SourceMetadataStorageWorker.kickoff_with_task(source) do
                  {:ok, _task} -> :ok
                  {:error, :duplicate_job} -> :ok
                  {:error, reason} -> {:error, reason}
                end

              case {indexing_res, metadata_res} do
                {:ok, :ok} ->
                  source

                {{:error, reason}, _} ->
                  Repo.rollback(reason)

                {_, {:error, reason}} ->
                  Repo.rollback(reason)
              end

            {:error, %Ecto.Changeset{} = err_cs} ->
              if unique_constraint_conflict?(err_cs) do
                Repo.rollback(:race_conflict)
              else
                Repo.rollback(err_cs)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      rescue
        _ in [Exqlite.Error, Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
          {:error, :database_exception}
      end

    case transaction_result do
      {:ok, %Source{} = source} ->
        {:ok, source}

      {:error, :race_conflict} ->
        case from(s in Source,
               where:
                 s.collection_type == :channel and
                   s.collection_id == ^channel_id and
                   s.media_profile_id == ^profile_id
             )
             |> Repo.all() do
          [single] -> {:error, {:already_tracked, single}}
          [_ | _] -> {:error, :ambiguous_copies}
          [] -> {:error, :race_conflict}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unique_constraint_conflict?(%Ecto.Changeset{} = changeset) do
    unique_error?(changeset.errors[:original_url]) or
      unique_error?(changeset.errors[:collection_id])
  end

  defp unique_error?({_msg, meta}) when is_list(meta) do
    Keyword.get(meta, :constraint) == :unique
  end

  defp unique_error?(_), do: false

  @doc """
  Checks if an Oban queue is currently paused.
  """
  def queue_paused?(queue_name, oban_name \\ Oban) do
    case Oban.check_queue(oban_name, queue: queue_name) do
      %{paused: true} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
