defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Downloading.MediaDownloader

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  @doc """
  Starts the media_item media download worker and creates a task for the media_item.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(media_item, job_args \\ %{}, job_opts \\ []) do
    maybe_replace_existing_manual_retry(media_item, job_args)

    %{id: media_item.id}
    |> Map.merge(job_args)
    |> MediaDownloadWorker.new(job_opts)
    |> Tasks.create_job_with_task(media_item)
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
    should_force = Map.get(args, "force", false)
    is_quality_upgrade = Map.get(args, "quality_upgrade?", false)
    should_reset_last_error = Map.get(args, "reset_last_error", false)

    media_item = fetch_and_run_prevent_download_user_script(media_item_id)

    maybe_reset_last_error(media_item, should_reset_last_error)

    if should_download_media?(media_item, should_force, is_quality_upgrade) do
      download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, should_reset_last_error, job_id)
    else
      :ok
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} stale")
  end

  # If this is a quality upgrade, only check if the source is set to download media
  # or that the media item's download hasn't been prevented
  defp should_download_media?(media_item, should_force, true = _is_quality_upgrade) do
    (media_item.source.download_media && !media_item.prevent_download) || should_force
  end

  # If it's not a quality upgrade, additionally check if the media item is pending download
  defp should_download_media?(media_item, should_force, _is_quality_upgrade) do
    source = media_item.source
    is_pending = Media.pending_download?(media_item)

    (is_pending && source.download_media && !media_item.prevent_download) || should_force
  end

  # If a user script exists and, when run, returns a non-zero exit code, prevent this and all future downloads
  # of the media item.
  defp fetch_and_run_prevent_download_user_script(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    {:ok, media_item} =
      case run_user_script(:media_pre_download, media_item) do
        {:ok, _, exit_code} when exit_code != 0 -> Media.update_media_item(media_item, %{prevent_download: true})
        _ -> {:ok, media_item}
      end

    Repo.preload(media_item, :source)
  end

  defp download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, should_reset_last_error, job_id) do
    overwrite_behaviour = if should_force || is_quality_upgrade, do: :force_overwrites, else: :no_force_overwrites

    override_opts = [
      overwrite_behaviour: overwrite_behaviour,
      progress_handler: build_progress_handler(job_id, reset_last_error?: should_reset_last_error),
      skip_download_precheck: should_skip_download_precheck?(media_item)
    ]

    case MediaDownloader.download_for_media_item(media_item, override_opts) do
      {:ok, downloaded_media_item} ->
        maybe_update_progress(job_id, %{progress_percent: 100.0, progress_status: "Finishing"})

        {:ok, updated_media_item} =
          Media.update_media_item(downloaded_media_item, %{
            media_size_bytes: compute_media_filesize(downloaded_media_item),
            media_redownloaded_at: get_redownloaded_at(is_quality_upgrade)
          })

        :ok = FileSyncing.delete_outdated_files(media_item, updated_media_item)
        run_user_script(:media_downloaded, updated_media_item)

        :ok

      {:recovered, _media_item, _message} ->
        {:error, :retry}

      {:error, :unsuitable_for_download, _message} ->
        {:ok, :non_retry}

      {:error, _error_atom, message} ->
        action_on_error(job_id, message)
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

  defp should_skip_download_precheck?(%{livestream: false, source: source}) do
    Sources.use_cookies?(source, :downloading)
  end

  defp should_skip_download_precheck?(_media_item), do: false

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

  defp action_on_error(job_id, message) do
    case classify_non_retryable_error(message) do
      {:ok, progress_status} ->
        maybe_update_progress(job_id, %{progress_status: progress_status})
        Logger.error("yt-dlp download will not be retried: #{inspect(message)}")
        {:ok, :non_retry}

      :error ->
        {:error, :download_failed}
    end
  end

  defp classify_non_retryable_error(message) do
    message = to_string(message)

    cond do
      String.contains?(message, rate_limited_errors()) ->
        {:ok, "Stopped: rate limited by remote source"}

      String.contains?(message, permanent_download_errors()) ->
        {:ok, "Stopped: download unavailable"}

      true ->
        :error
    end
  end

  defp rate_limited_errors do
    [
      "HTTP Error 429",
      "Too Many Requests",
      "rate limit",
      "rate-limit",
      "requested too many",
      "confirm you're not a bot",
      "confirm you’re not a bot"
    ]
  end

  defp permanent_download_errors do
    [
      "Video unavailable",
      "Sign in to confirm",
      "This video is available to this channel's members"
    ]
  end

  # NOTE: I like this pattern of using the default value so that I don't have to
  # define it in config.exs (and friends). Consider using this elsewhere.
  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
