defmodule Pinchflat.SlowIndexing.SlowIndexingHelpers do
  @moduledoc """
  Methods for performing slow indexing tasks and managing the indexing process.

  Many of these methods are made to be kickoff or be consumed by workers.
  """

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.FileFollowerServer
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @doc """
  Kills old indexing tasks and starts a new task to index the media collection.

  The job is delayed based on the source's `index_frequency_minutes` setting unless
  one of the following is true:
    - The `force` option is set to true
    - The source has never been indexed before
    - The source has been indexed before, but the last indexing job was more than
      `index_frequency_minutes` ago

  Returns {:ok, %Task{}}
  """
  def kickoff_indexing_task(%Source{} = source, job_args \\ %{}, job_opts \\ []) do
    job_offset_seconds = if job_args[:force], do: 0, else: calculate_job_offset_seconds(source)

    Tasks.delete_pending_tasks_for(source, "MediaCollectionIndexingWorker", include_executing: true)

    MediaCollectionIndexingWorker.kickoff_with_task(source, job_args, job_opts ++ [schedule_in: job_offset_seconds])
  end

  @doc """
  A helper method to delete all indexing-related tasks for a source.
  Optionally, you can include executing tasks in the deletion process.

  Returns :ok
  """
  def delete_indexing_tasks(%Source{} = source, opts \\ []) do
    include_executing = Keyword.get(opts, :include_executing, false)

    Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: include_executing)
    Tasks.delete_pending_tasks_for(source, "MediaCollectionIndexingWorker", include_executing: include_executing)
  end

  @doc """
  Given a media source, creates (indexes) the media by creating media_items for each
  media ID in the source. Afterward, kicks off a download task for each pending media
  item belonging to the source. Returns a list of media items or changesets
  (if the media item couldn't be created).

  Indexing is slow and usually returns a list of all media data at once for record creation.
  To help with this, we use a file follower to watch the file that yt-dlp writes to
  so we can create media items as they come in. This parallelizes the process and adds
  clarity to the user experience. This has a few things to be aware of which are documented
  below in the file watcher setup method.

  Additionally, in the case of a repeat index we create a download archive file that
  contains some media IDs that we've indexed in the past. Note that this archive doesn't
  contain the most recent IDs but rather a subset of IDs that are offset by some amount.
  Practically, this means that we'll re-index a small handful of media that we've recently
  indexed, but this is a good thing since it'll let us pick up on any recent changes to the
  most recent media items.

  We don't create a download archive for playlists (only channels), nor do we create one if
  the indexing was forced by the user.

  NOTE: downloads are only enqueued if the source is set to download media. Downloads are
  also enqueued for ALL pending media items, not just the ones that were indexed in this
  job run. This should ensure that any stragglers are caught if, for some reason, they
  weren't enqueued or somehow got de-queued.

  Available options:
    - `was_forced`: Whether the indexing was forced by the user

  Returns [%MediaItem{} | %Ecto.Changeset{}]
  """
  def index_and_enqueue_download_for_media_items(%Source{} = source, opts \\ []) do
    # The media_profile is needed to determine the quality options to _then_ determine a more
    # accurate predicted filepath
    source = Repo.preload(source, [:media_profile])
    # See the method definition below for more info on how file watchers work
    # (important reading if you're not familiar with it)
    {:ok, media_attributes} = setup_file_watcher_and_kickoff_indexing(source, opts)
    # Reload because the source may have been updated during the (long-running) indexing process
    # and important settings like `download_media` may have changed.
    source = Repo.reload!(source)

    result =
      Enum.map(media_attributes, fn media_attrs ->
        case Media.create_media_item_from_backend_attrs(source, media_attrs) do
          {:ok, media_item} -> media_item
          {:error, changeset} -> changeset
        end
      end)

    update_source_after_indexing(source)
    DownloadingHelpers.enqueue_pending_download_tasks(source)

    result
  end

  # The file follower is a GenServer that watches a file for new lines and
  # processes them. This works well, but we have to be resilliant to partially-written
  # lines (ie: you should gracefully fail if you can't parse a line).
  #
  # This works in-tandem with the normal (blocking) media indexing behaviour. When
  # the `setup_file_watcher_and_kickoff_indexing` method completes it'll return the
  # FULL result to the caller for parsing. Ideally, every item in the list will have already
  # been processed by the file follower, but if not, the caller handles creation
  # of any media items that were missed/initially failed.
  #
  # It attempts a graceful shutdown of the file follower after the indexing is done,
  # but the FileFollowerServer will also stop itself if it doesn't see any activity
  # for a sufficiently long time.
  defp setup_file_watcher_and_kickoff_indexing(source, opts) do
    was_forced = Keyword.get(opts, :was_forced, false)
    {:ok, pid} = FileFollowerServer.start_link()

    handler = fn filepath -> setup_file_follower_watcher(pid, filepath, source) end
    should_use_cookies = Sources.use_cookies?(source, :indexing)

    command_opts =
      [output: DownloadOptionBuilder.build_output_path_for(source)] ++
        DownloadOptionBuilder.build_quality_options_for(source) ++
        build_download_archive_options(source, was_forced) ++
        build_dateafter_options(source)

    runner_opts = [file_listener_handler: handler, use_cookies: should_use_cookies]
    result = MediaCollection.get_media_attributes_for_collection(source.original_url, command_opts, runner_opts)

    FileFollowerServer.stop(pid)

    result
  end

  defp setup_file_follower_watcher(pid, filepath, source) do
    FileFollowerServer.watch_file(pid, filepath, fn line ->
      case Phoenix.json_library().decode(line) do
        {:ok, media_attrs} ->
          Logger.debug("FileFollowerServer Handler: Got media attributes: #{inspect(media_attrs)}")

          media_struct = YtDlpMedia.response_to_struct(media_attrs)
          create_media_item_and_enqueue_download(source, media_struct)

        err ->
          Logger.debug("FileFollowerServer Handler: Error decoding JSON: #{inspect(err)}")

          err
      end
    end)
  end

  defp create_media_item_and_enqueue_download(source, media_attrs) do
    # Reload because the source may have been updated during the (long-running) indexing process
    # and important settings like `download_media` may have changed.
    source = Repo.reload!(source)

    case Media.create_media_item_from_backend_attrs(source, media_attrs) do
      {:ok, %MediaItem{} = media_item} ->
        DownloadingHelpers.kickoff_download_if_pending(media_item)

      {:error, changeset} ->
        changeset
    end
  end

  # Find the difference between the current time and the last time the source was indexed
  defp calculate_job_offset_seconds(%Source{last_indexed_at: nil}), do: 0

  defp calculate_job_offset_seconds(source) do
    offset_seconds = DateTime.diff(DateTime.utc_now(), source.last_indexed_at, :second)
    index_frequency_seconds = source.index_frequency_minutes * 60

    max(0, index_frequency_seconds - offset_seconds)
  end

  # The download archive file works in tandem with --break-on-existing to stop
  # yt-dlp once we've hit media items we've already indexed. But we generate
  # this list with a bit of an offset so we do intentionally re-scan some media
  # items to pick up any recent changes (see `get_media_items_for_download_archive`).
  #
  # From there, we format the media IDs in the way that yt-dlp expects (ie: "<extractor> <media_id>")
  # and return the filepath to the caller.
  defp create_download_archive_file(source) do
    tmpfile = FilesystemUtils.generate_metadata_tmpfile(:txt)

    archive_contents =
      source
      |> get_media_items_for_download_archive()
      |> Enum.map_join("\n", fn media_item -> "youtube #{media_item.media_id}" end)

    case File.write(tmpfile, archive_contents) do
      :ok -> tmpfile
      err -> err
    end
  end

  # Sorting by `uploaded_at` is important because we want to re-index the most recent
  # media items first but there is no guarantee of any correlation between ID and uploaded_at.
  #
  # The offset is important because we want to re-index some media items that we've
  # recently indexed to pick up on any changes. The limit is because we want this mechanism
  # to work even if, for example, the video we were using as a stopping point was deleted.
  # It's not a perfect system, but it should do well enough.
  #
  # The chosen limit and offset are arbitary, independent, and vibes-based. Feel free to
  # tweak as-needed
  defp get_media_items_for_download_archive(source) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> order_by(desc: :uploaded_at)
    |> limit(50)
    |> offset(20)
    |> Repo.all()
  end

  # The download archive isn't useful for playlists (since those are ordered arbitrarily)
  # and we don't want to use it if the indexing was forced by the user. In other words,
  # only create an archive for channels that are being indexed as part of their regular
  # indexing schedule. The first indexing pass should also not create an archive.
  defp build_download_archive_options(%Source{collection_type: :playlist}, _was_forced), do: []
  defp build_download_archive_options(%Source{collection_type: :video}, _was_forced), do: []
  defp build_download_archive_options(%Source{last_indexed_at: nil}, _was_forced), do: []
  defp build_download_archive_options(_source, true), do: []

  defp build_download_archive_options(source, _was_forced) do
    archive_file = create_download_archive_file(source)

    [:break_on_existing, download_archive: archive_file]
  end

  # Builds the --dateafter option for yt-dlp to skip videos older than a calculated
  # effective scan date. This is determined by taking the most recent of:
  # 1. The source's download_cutoff_date
  # 2. Today minus retention_period_days minus a buffer (for sources with retention)
  #
  # The buffer (3 days) accounts for upload delays and timezone differences.
  # This optimization dramatically reduces indexing time for sources with short
  # retention periods - instead of scanning thousands of old videos, we only
  # scan videos that could potentially be downloaded and retained.
  @dateafter_buffer_days 3
  defp build_dateafter_options(%Source{} = source) do
    effective_date = calculate_effective_scan_date(source)

    case effective_date do
      nil -> []
      date -> [dateafter: Date.to_iso8601(date, :basic)]
    end
  end

  # Calculates the effective scan date by comparing the download_cutoff_date
  # with a retention-based date (if applicable). Returns the more recent of the two,
  # since there's no point scanning videos older than either threshold.
  defp calculate_effective_scan_date(%Source{} = source) do
    cutoff_date = source.download_cutoff_date
    retention_date = calculate_retention_based_date(source)

    case {cutoff_date, retention_date} do
      {nil, nil} -> nil
      {cutoff, nil} -> cutoff
      {nil, retention} -> retention
      {cutoff, retention} -> max_date(cutoff, retention)
    end
  end

  # For sources with retention, calculate a date based on retention_period_days + buffer.
  # Returns nil if retention is not set (nil or 0 means keep forever).
  defp calculate_retention_based_date(%Source{retention_period_days: nil}), do: nil
  defp calculate_retention_based_date(%Source{retention_period_days: 0}), do: nil

  defp calculate_retention_based_date(%Source{retention_period_days: retention_days}) do
    # Add buffer days to account for upload delays and ensure we don't miss edge cases
    days_to_scan = retention_days + @dateafter_buffer_days
    Date.utc_today() |> Date.add(-days_to_scan)
  end

  defp max_date(date1, date2) do
    if Date.compare(date1, date2) == :gt, do: date1, else: date2
  end

  # Updates the source after a successful indexing run. This includes:
  # - Setting `last_indexed_at` to the current time
  # - Advancing `download_cutoff_date` to 7 days ago if it's older (or nil)
  # - Kicking off metadata storage if source images are missing but should be downloaded
  #
  # Advancing the cutoff date prevents yt-dlp from scanning through months of old videos
  # on every index. We use 7 days as a buffer to ensure we don't miss any videos that
  # might have been uploaded just before the cutoff.
  #
  # We use `run_post_commit_tasks: false` to avoid triggering side effects like
  # re-indexing or metadata storage since this is an internal update.
  defp update_source_after_indexing(source) do
    new_cutoff_date = Date.utc_today() |> Date.add(-7)

    update_attrs =
      %{last_indexed_at: DateTime.utc_now()}
      |> maybe_advance_cutoff_date(source.download_cutoff_date, new_cutoff_date)

    Sources.update_source(source, update_attrs, run_post_commit_tasks: false)

    maybe_kickoff_metadata_storage_for_missing_images(source)
  end

  defp maybe_advance_cutoff_date(attrs, nil, new_cutoff_date) do
    Map.put(attrs, :download_cutoff_date, new_cutoff_date)
  end

  defp maybe_advance_cutoff_date(attrs, current_cutoff_date, new_cutoff_date) do
    if Date.compare(current_cutoff_date, new_cutoff_date) == :lt do
      Map.put(attrs, :download_cutoff_date, new_cutoff_date)
    else
      attrs
    end
  end

  # Kicks off metadata storage if source images should be downloaded but are missing.
  # This handles the case where:
  # 1. A source was created before download_source_images was enabled on the profile
  # 2. The source metadata worker failed or was interrupted
  # 3. The profile's download_source_images setting was later enabled
  defp maybe_kickoff_metadata_storage_for_missing_images(source) do
    source = Repo.preload(source, :media_profile)

    if source.media_profile.download_source_images && source_images_missing?(source) do
      Logger.info("Source #{source.id} is missing images, kicking off metadata storage")
      SourceMetadataStorageWorker.kickoff_with_task(source)
    end

    :ok
  end

  defp source_images_missing?(source) do
    is_nil(source.poster_filepath) || is_nil(source.fanart_filepath)
  end
end
