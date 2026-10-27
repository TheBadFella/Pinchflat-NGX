defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing, :suspended]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger
  import Ecto.Query, only: [from: 2]

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Settings
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Media.DownloadState
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.YtDlp.UnavailableMedia
  alias Pinchflat.Downloading.DownloadError
  alias Pinchflat.Downloading.FirstArtifact
  alias Pinchflat.Downloading.MediaDownloader
  alias Pinchflat.Downloading.SpaceProtection

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner
  alias Pinchflat.MediaServers
  alias Pinchflat.MediaWatch

  @doc """
  Starts the media_item media download worker and creates a task for the media_item.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(media_item, job_args \\ %{}, job_opts \\ []) do
    Repo.transaction(fn ->
      maybe_replace_existing_manual_retry(media_item, job_args)

      result =
        %{id: media_item.id}
        |> Map.merge(job_args)
        |> MediaDownloadWorker.new(job_opts)
        |> Tasks.create_job_with_task(media_item)

      case result do
        {:ok, task} -> task
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  For a given media item, download the media alongside any options.
  Does not download media if its source is set to not download media
  (unless forced).

  Options:
    - `force`: force download even if the source is set to not download media. Fully
      re-downloads media, including the video
    - `quality_upgrade?`: re-downloads media, including the video. Does not force download
      if the source is set to not download media

  Returns :ok | {:error, any, ...any}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"id" => media_item_id} = args}) do
    case SpaceProtection.preflight(job_id) do
      :ok ->
        should_force = Map.get(args, "force", false)
        is_quality_upgrade = Map.get(args, "quality_upgrade?", false)
        should_reset_last_error = Map.get(args, "reset_last_error", false)

        current = Media.get_media_item!(media_item_id)

        cond do
          not is_nil(current.watch_enrollment_pending_at) or
              (not is_nil(current.watch_download_started_at) and current.watch_postprocessing_pending) ->
            if current.watch_postprocessing_pending do
              finish_first_download_postprocessing(current, current, false)
            else
              finish_pending_download(current)
            end

          current.watch_download_started_at && is_nil(current.media_downloaded_at) && FirstArtifact.pending?(current) ->
            resume_first_artifact(current)

          true ->
            media_item = fetch_and_run_prevent_download_user_script(media_item_id)
            maybe_reset_last_error(media_item, should_reset_last_error)

            case should_download_media(media_item, should_force, is_quality_upgrade) do
              :ok ->
                download_media_and_schedule_jobs(
                  media_item,
                  is_quality_upgrade,
                  should_force,
                  should_reset_last_error,
                  job_id
                )

              {:skip, reason} ->
                Logger.info(
                  "media_download_skipped media_item_id=#{media_item.id} source_id=#{media_item.source_id} reason=#{reason}"
                )

                :ok
            end
        end

      {:snooze, seconds} ->
        {:snooze, seconds}
    end
  rescue
    Ecto.NoResultsError ->
      Logger.info("#{__MODULE__} discarded: media item #{media_item_id} not found")

    Ecto.StaleEntryError ->
      Logger.info("#{__MODULE__} discarded: media item #{media_item_id} stale")

    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("media download state unavailable for item ##{media_item_id}: #{inspect(error)}")
      {:error, :download_state_unavailable}
  end

  # Recheck retention here because media may have expired while its upgrade was queued.
  # Forced downloads retain their explicit override of automatic download restrictions.
  defp should_download_media(media_item, should_force, true = _is_quality_upgrade) do
    cond do
      MediaWatch.replacement_blocked?(media_item.id) -> {:skip, :watch_guard}
      should_force -> :ok
      !media_item.source.download_media -> {:skip, :source_downloads_disabled}
      media_item.prevent_download -> {:skip, :item_prevented}
      Media.retention_cullable?(media_item) -> {:skip, :retention_expired}
      true -> :ok
    end
  end

  # If it's not a quality upgrade, additionally check if the media item is pending download
  defp should_download_media(media_item, should_force, _is_quality_upgrade) do
    source = media_item.source
    is_pending = Media.pending_download?(media_item)

    cond do
      MediaWatch.replacement_blocked?(media_item.id) -> {:skip, :watch_guard}
      should_force -> :ok
      !source.download_media -> {:skip, :source_downloads_disabled}
      media_item.prevent_download -> {:skip, :item_prevented}
      is_pending -> :ok
      media_item.watch_download_started_at && is_nil(media_item.media_downloaded_at) -> :ok
      true -> {:skip, skip_reason_for_not_pending(media_item)}
    end
  end

  # If a user script exists and, when run, returns a non-zero exit code, prevent this and all future downloads
  # of the media item.
  defp fetch_and_run_prevent_download_user_script(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    {:ok, media_item} =
      case run_user_script(:media_pre_download, media_item) do
        {:ok, _, exit_code} when exit_code != 0 ->
          Media.update_download_state(media_item, {:manual, true})

        _ ->
          {:ok, media_item}
      end

    Repo.preload(media_item, source: :media_profile)
  end

  defp download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, should_reset_last_error, job_id) do
    overwrite_behaviour = if should_force || is_quality_upgrade, do: :force_overwrites, else: :no_force_overwrites

    override_opts = [
      job_id: job_id,
      overwrite_behaviour: overwrite_behaviour,
      progress_handler: build_progress_handler(job_id, reset_last_error?: should_reset_last_error),
      skip_download_precheck: should_skip_download_precheck?(media_item)
    ]

    # This marker is created only for a previously undownloaded item. A partial
    # metadata write can add a filepath, but cannot make its retry an old library.
    media_item =
      if is_nil(media_item.media_downloaded_at) and is_nil(media_item.media_filepath) and
           is_nil(media_item.watch_download_started_at) do
        {:ok, started} =
          Media.update_media_item(media_item, %{
            watch_download_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        started
      else
        media_item
      end

    case MediaDownloader.download_for_media_item(media_item, override_opts) do
      {:ok, downloaded_media_item} ->
        maybe_update_progress(job_id, %{progress_percent: 100.0, progress_status: "Finishing"})

        finish_first_download_postprocessing(media_item, downloaded_media_item, is_quality_upgrade)

      {:recovered, recovered_media_item, _message} ->
        persist_download_failure(recovered_media_item, :transient, should_force)
        {:error, :retry}

      {:error, :unsuitable_for_download, _message} ->
        persist_download_failure(media_item, :transient, should_force)
        {:ok, :non_retry}

      {:error, :staging_unavailable, message} ->
        persist_download_failure(media_item, :transient, should_force)
        maybe_update_progress(job_id, %{progress_status: message})
        {:ok, :non_retry}

      {:error, :cancelled, message} ->
        maybe_update_progress(job_id, %{progress_status: message})
        {:cancel, message}

      {:error, :migration_hold, _message} ->
        maybe_update_progress(job_id, %{progress_status: "Database migration in progress, retrying later"})
        {:snooze, 30}

      {:error, :insufficient_storage, message} ->
        maybe_update_progress(job_id, %{progress_status: message})
        {:snooze, 60}

      {:error, :artifact_persistence_failed, message} ->
        maybe_update_progress(job_id, %{progress_status: message})
        {:error, :artifact_persistence_failed}

      {:error, :filtered, message} ->
        persist_download_failure(media_item, :permanent, should_force)
        maybe_update_progress(job_id, %{progress_status: "Skipped: does not match download filters"})
        Logger.info("yt-dlp download skipped by filter: #{inspect(message)}")
        {:ok, :non_retry}

      {:error, _error_atom, message} ->
        maybe_ignore_unavailable_media(media_item, job_id, message, should_force)
    end
  end

  defp resume_first_artifact(item) do
    with {:ok, metadata} <- FirstArtifact.recover(item),
         {:ok, recovered} <- MediaDownloader.restore_first_artifact(item, metadata) do
      finish_first_download_postprocessing(item, recovered, false)
    else
      {:error, reason} ->
        Logger.error("first artifact recovery failed for media item ##{item.id}: #{inspect(reason)}")
        {:error, :first_artifact_needs_recovery}

      {:error, reason, _message} ->
        Logger.error("first artifact recovery failed for media item ##{item.id}: #{inspect(reason)}")
        {:error, :first_artifact_needs_recovery}
    end
  rescue
    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("first artifact recovery write failed for item ##{item.id}: #{inspect(error)}")
      {:error, :first_artifact_needs_recovery}
  end

  defp finish_first_download_postprocessing(old_item, downloaded_item, is_quality_upgrade) do
    # Only a successful application postprocessing run completes the artifact.
    first? = is_nil(old_item.media_downloaded_at) and downloaded_item.watch_postprocessing_pending
    :ok = FileSyncing.delete_outdated_files(old_item, downloaded_item)

    script_result =
      if first? and FirstArtifact.completed_at(downloaded_item) do
        :ok
      else
        run_user_script(:media_downloaded, downloaded_item)
      end

    # The default-off lifecycle script remains advisory. A prospective watched
    # artifact is not complete until its configured script exits successfully.
    if first? and not script_succeeded?(script_result) do
      {:error, :postprocessing_failed}
    else
      complete_download_postprocessing(downloaded_item, is_quality_upgrade, first?)
    end
  rescue
    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("media finalization write failed for item ##{downloaded_item.id}: #{inspect(error)}")
      {:error, :finalization_failed}
  end

  defp script_succeeded?(:ok), do: true
  defp script_succeeded?({:ok, :no_executable}), do: true
  defp script_succeeded?({:ok, _, 0}), do: true
  defp script_succeeded?(_), do: false

  defp complete_download_postprocessing(downloaded_item, is_quality_upgrade, first?) do
    attrs = %{
      media_size_bytes: compute_media_filesize(downloaded_item),
      media_redownloaded_at: get_redownloaded_at(is_quality_upgrade)
    }

    attrs =
      if first? do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case FirstArtifact.mark_completed(downloaded_item, now) do
          :ok ->
            attrs
            |> Map.put(:watch_postprocessing_pending, false)
            |> Map.put(:watch_enrollment_pending_at, FirstArtifact.completed_at(downloaded_item) || now)

          {:error, reason} ->
            {:error, reason}
        end
      else
        attrs
      end

    case attrs do
      {:error, reason} ->
        Logger.error("first artifact completion marker failed for item ##{downloaded_item.id}: #{inspect(reason)}")
        {:error, :finalization_failed}

      attrs ->
        finalize_download_postprocessing(downloaded_item, first?, attrs)
    end
  end

  defp finalize_download_postprocessing(downloaded_item, first?, attrs) do
    result =
      if first? do
        Repo.transaction(fn ->
          # Reserve before reading: both SQLite and PostgreSQL must see the
          # current phase rather than applying a stale worker's finalization.
          Repo.update_all(from(item in MediaItem, where: item.id == ^downloaded_item.id),
            set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
          )

          current = Repo.get!(MediaItem, downloaded_item.id)

          cond do
            not is_nil(current.media_downloaded_at) or not is_nil(current.watch_enrollment_pending_at) ->
              current

            current.watch_postprocessing_pending ->
              case Media.update_media_item(current, attrs) do
                {:ok, updated} -> updated
                {:error, reason} -> Repo.rollback(reason)
              end

            true ->
              Repo.rollback(:first_artifact_state_changed)
          end
        end)
      else
        Media.update_media_item(downloaded_item, attrs)
      end

    case result do
      {:ok, updated} ->
        if first? do
          finish_pending_download(updated)
        else
          MediaServers.dispatch_post_download_refresh(updated)
          :ok
        end

      {:error, reason} ->
        Logger.error("media finalization failed for media item ##{downloaded_item.id}: #{inspect(reason)}")
        {:error, :finalization_failed}
    end
  rescue
    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("media finalization write failed for item ##{downloaded_item.id}: #{inspect(error)}")
      {:error, :finalization_failed}
  end

  defp finish_pending_download(item) do
    case MediaWatch.complete_pending_download(item) do
      {:ok, completed} ->
        MediaServers.dispatch_post_download_refresh(completed)
        FirstArtifact.clear(completed)
        :ok

      {:error, reason} ->
        Logger.error("media_watch enrollment failed for media item ##{item.id}: #{inspect(reason)}")
        {:error, :enrollment_failed}
    end
  rescue
    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("media_watch enrollment write failed for item ##{item.id}: #{inspect(error)}")
      {:error, :enrollment_failed}
  end

  # If the "ignore unavailable media" setting is enabled and the error indicates the
  # media is permanently inaccessible (members-only, private, or removed), keep the
  # existing unavailable metadata while recording the durable permanent state.
  defp maybe_ignore_unavailable_media(media_item, job_id, message, should_force) do
    if Settings.get!(:ignore_unavailable_media) && UnavailableMedia.error?(message) do
      Logger.info("Ignoring unavailable media item ##{media_item.id}: #{inspect(message)}")

      unavailable_attrs = %{
        unavailable_at: DateTime.utc_now(),
        unavailable_reason: UnavailableMedia.matched_reason(message)
      }

      current_media_item = Repo.reload!(media_item)
      state_attrs = DownloadState.transition(current_media_item, {:failure, :permanent, should_force})
      {:ok, _} = Media.update_media_item(current_media_item, Map.merge(state_attrs, unavailable_attrs))

      {:ok, :non_retry}
    else
      action_on_error(media_item, job_id, message, should_force)
    end
  end

  defp build_progress_handler(job_id, opts) do
    initial_status = if Keyword.get(opts, :reset_last_error?, false), do: "Retry requested", else: "Queued"
    maybe_update_progress(job_id, %{progress_percent: 0.0, progress_status: initial_status})

    fn attrs ->
      maybe_update_progress(job_id, attrs)
    end
  end

  defp maybe_reset_last_error(_media_item, false), do: :ok
  defp maybe_reset_last_error(%{last_error: nil}, true), do: :ok

  defp maybe_reset_last_error(media_item, true) do
    {:ok, _media_item} = Media.update_media_item(media_item, %{last_error: nil})
    :ok
  end

  defp should_skip_download_precheck?(%{livestream: false}), do: true

  defp should_skip_download_precheck?(_media_item), do: false

  defp skip_reason_for_not_pending(media_item) do
    source = media_item.source
    media_profile = source.media_profile

    cond do
      media_item.media_filepath ->
        :item_not_pending

      before_cutoff?(media_item, source) ->
        :format_or_profile_mismatch

      too_short?(media_item, source) ->
        :format_or_profile_mismatch

      too_long?(media_item, source) ->
        :format_or_profile_mismatch

      media_profile.shorts_behaviour == :exclude && media_item.short_form_content ->
        :format_or_profile_mismatch

      media_profile.shorts_behaviour == :only && !media_item.short_form_content ->
        :format_or_profile_mismatch

      media_profile.livestream_behaviour == :exclude && media_item.livestream ->
        :format_or_profile_mismatch

      media_profile.livestream_behaviour == :only && !media_item.livestream ->
        :format_or_profile_mismatch

      is_binary(source.title_filter_regex) ->
        :format_or_profile_mismatch

      true ->
        :item_not_pending
    end
  end

  defp before_cutoff?(media_item, %{download_cutoff_date: %Date{} = cutoff_date})
       when not is_nil(media_item.uploaded_at) do
    Date.compare(DateTime.to_date(media_item.uploaded_at), cutoff_date) == :lt
  end

  defp before_cutoff?(_media_item, _source), do: false

  defp too_short?(media_item, %{min_duration_seconds: min_duration})
       when not is_nil(min_duration) and not is_nil(media_item.duration_seconds) do
    media_item.duration_seconds < min_duration
  end

  defp too_short?(_media_item, _source), do: false

  defp too_long?(media_item, %{max_duration_seconds: max_duration})
       when not is_nil(max_duration) and not is_nil(media_item.duration_seconds) do
    media_item.duration_seconds > max_duration
  end

  defp too_long?(_media_item, _source), do: false

  defp maybe_replace_existing_manual_retry(media_item, job_args) do
    if Map.get(job_args, :reset_last_error) || Map.get(job_args, "reset_last_error") do
      Tasks.delete_pending_tasks_for(media_item)
    else
      :ok
    end
  end

  defp maybe_update_progress(nil, _attrs), do: :ok

  defp maybe_update_progress(job_id, attrs) do
    case Tasks.get_task_by_job_id(job_id) do
      nil ->
        :ok

      task ->
        percent = Map.get(attrs, :progress_percent)
        status = Map.get(attrs, :progress_status)
        now_ms = System.monotonic_time(:millisecond)
        last_ms = Process.get({:progress_updated_ms, job_id}, 0)
        last_percent = Process.get({:progress_percent, job_id})
        last_status = Process.get({:progress_status, job_id})

        should_update =
          is_nil(last_percent) ||
            percent == 100.0 ||
            status != last_status ||
            now_ms - last_ms >= 1_000 ||
            percent_change_exceeds_threshold?(percent, last_percent)

        if should_update do
          Process.put({:progress_updated_ms, job_id}, now_ms)
          Process.put({:progress_percent, job_id}, percent)
          Process.put({:progress_status, job_id}, status)

          Tasks.update_task_progress(task, attrs)
        else
          :ok
        end
    end
  end

  defp percent_change_exceeds_threshold?(nil, _last_percent), do: false
  defp percent_change_exceeds_threshold?(_percent, nil), do: true

  defp percent_change_exceeds_threshold?(percent, last_percent) do
    abs(percent - last_percent) >= 2.0
  end

  defp compute_media_filesize(media_item) do
    case File.stat(media_item.media_filepath) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp get_redownloaded_at(true), do: DateTime.utc_now()
  defp get_redownloaded_at(_), do: nil

  defp action_on_error(media_item, job_id, message, should_force) do
    case DownloadError.classify(message) do
      {:rate_limited, progress_status} ->
        persist_download_failure(media_item, :transient, should_force)
        maybe_update_progress(job_id, %{progress_status: progress_status})
        Logger.error("yt-dlp download will not be retried: #{inspect(message)}")
        {:ok, :non_retry}

      {:permanent, progress_status} ->
        persist_download_failure(media_item, :permanent, should_force)
        maybe_update_progress(job_id, %{progress_status: progress_status})
        Logger.error("yt-dlp download will not be retried: #{inspect(message)}")
        {:ok, :non_retry}

      :transient ->
        persist_download_failure(media_item, :transient, should_force)
        {:error, :download_failed}
    end
  end

  defp persist_download_failure(media_item, error_type, should_force) do
    current_media_item = Repo.reload!(media_item)
    attrs = DownloadState.transition(current_media_item, {:failure, error_type, should_force})
    {:ok, _} = Media.update_media_item(current_media_item, attrs)
    :ok
  end

  # NOTE: I like this pattern of using the default value so that I don't have to
  # define it in config.exs (and friends). Consider using this elsewhere.
  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
