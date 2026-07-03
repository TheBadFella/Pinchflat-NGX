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

  YouTube channels are indexed one tab at a time (videos, shorts, streams) as separate
  yt-dlp invocations. This matters because `--break-on-existing` aborts the whole yt-dlp
  process — not just the current tab — so indexing a bare channel URL with a download
  archive would stop at the first known video and never reach the shorts or streams tabs.
  Indexing each tab separately (with an archive filtered to that tab's content type) lets
  the early-abort optimization work per-tab without starving the others.

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
    enqueued_download_count = DownloadingHelpers.enqueue_pending_download_tasks(source)

    Logger.info(
      "indexing_completed source_id=#{source.id} indexed_media_count=#{length(media_attributes)} " <>
        "created_media_count=#{Enum.count(result, &match?(%MediaItem{}, &1))} " <>
        "pending_downloads_enqueued=#{enqueued_download_count} download_media=#{source.download_media}"
    )

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
    should_use_cookies = Sources.use_cookies?(source, :indexing)

    base_command_opts =
      [output: DownloadOptionBuilder.build_output_path_for(source)] ++
        build_single_video_options(source) ++
        DownloadOptionBuilder.build_quality_options_for(source) ++
        build_dateafter_options(source)

    results =
      Enum.map(indexing_urls_for(source), fn {url, content_type} ->
        command_opts = base_command_opts ++ build_download_archive_options(source, was_forced, content_type)

        run_indexing_command(source, url, command_opts, should_use_cookies)
      end)

    # A channel can legitimately lack a shorts or streams tab (yt-dlp errors out
    # on those), so a failed URL only fails the index if no URL succeeded at all.
    # Tabs shouldn't overlap in content, but dedupe across them just in case.
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {[], [first_error | _]} ->
        first_error

      {successes, _} ->
        media_attributes =
          successes
          |> Enum.flat_map(fn {:ok, media_attributes} -> media_attributes end)
          |> Enum.uniq_by(& &1.media_id)

        {:ok, media_attributes}
    end
  end

  defp run_indexing_command(source, url, command_opts, should_use_cookies) do
    {:ok, pid} = FileFollowerServer.start_link()

    handler = fn filepath -> setup_file_follower_watcher(pid, filepath, source) end

    # Exit code 1 is declared as expected so the runner logs it at debug instead
    # of error — failures are logged here instead, where we can tell a channel
    # legitimately missing a shorts/streams tab apart from a real error.
    runner_opts = [
      file_listener_handler: handler,
      use_cookies: should_use_cookies,
      expected_exit_codes: [1]
    ]

    result = MediaCollection.get_media_attributes_for_collection(url, command_opts, runner_opts)

    FileFollowerServer.stop(pid)

    case result do
      {:ok, media_attributes} ->
        {:ok, media_attributes}

      err ->
        log_indexing_failure(url, err)
        err
    end
  end

  # A channel not having a shorts/streams/live tab is a normal state of affairs,
  # not something to warn about on every scheduled index.
  defp log_indexing_failure(url, {:error, message, _status} = err) when is_binary(message) do
    if message =~ ~r/does not have a \S+ tab/ do
      Logger.debug("Indexing skipped for #{url}: #{String.trim(message)}")
    else
      Logger.warning("Indexing failed for #{url}: #{inspect(err)}")
    end
  end

  defp log_indexing_failure(url, err) do
    Logger.warning("Indexing failed for #{url}: #{inspect(err)}")
  end

  # YouTube channels are indexed one content tab at a time because `--break-on-existing`
  # aborts the entire yt-dlp process, not just the current tab — indexing a bare channel
  # URL with a download archive stops at the first known video and never reaches the
  # shorts or streams tabs (see moduledoc). Channels whose URL already names a tab are
  # respected as-is, and playlists/non-YouTube sources are passed through untouched.
  defp indexing_urls_for(%Source{collection_type: :channel} = source) do
    explicit_tab = explicit_channel_tab(source.original_url)

    cond do
      not String.contains?(source.original_url, "youtube.com") ->
        [{source.original_url, :all}]

      explicit_tab ->
        [{source.original_url, explicit_tab}]

      true ->
        Enum.map([:videos, :shorts, :streams], fn tab ->
          {"https://www.youtube.com/channel/#{source.collection_id}/#{tab}", tab}
        end)
    end
  end

  defp indexing_urls_for(source), do: [{source.original_url, :all}]

  defp explicit_channel_tab(url) do
    case Regex.run(~r{youtube\.com/.+/(videos|shorts|streams|live)/?(?:\?.*)?$}, url) do
      [_, "videos"] -> :videos
      [_, "shorts"] -> :shorts
      [_, "streams"] -> :streams
      [_, "live"] -> :streams
      _ -> nil
    end
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
        maybe_kickoff_download_if_pending(source, media_item)

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
  # The archive only contains media matching the content tab being indexed —
  # a short in the videos tab's archive would never match anything and would
  # eat into the re-scan buffer.
  #
  # From there, we format the media IDs in the way that yt-dlp expects (ie: "<extractor> <media_id>")
  # and return the filepath to the caller.
  defp create_download_archive_file(source, content_type) do
    tmpfile = FilesystemUtils.generate_metadata_tmpfile(:txt)

    archive_contents =
      source
      |> get_media_items_for_download_archive(content_type)
      |> Enum.map_join("\n", fn media_item -> "youtube #{media_item.media_id}" end)

    case File.write(tmpfile, archive_contents) do
      :ok -> {:ok, tmpfile}
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
  defp get_media_items_for_download_archive(source, content_type) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> where(^content_type_filter(content_type))
    |> order_by(desc: :uploaded_at)
    |> limit(50)
    |> offset(20)
    |> Repo.all()
  end

  defp content_type_filter(:videos), do: dynamic([mi], mi.short_form_content == false and mi.livestream == false)
  defp content_type_filter(:shorts), do: dynamic([mi], mi.short_form_content == true)
  defp content_type_filter(:streams), do: dynamic([mi], mi.livestream == true)
  defp content_type_filter(:all), do: dynamic(true)

  # The download archive isn't useful for playlists (since those are ordered arbitrarily)
  # and we don't want to use it if the indexing was forced by the user. In other words,
  # only create an archive for channels that are being indexed as part of their regular
  # indexing schedule. The first indexing pass should also not create an archive.
  defp build_download_archive_options(%Source{collection_type: :playlist}, _was_forced, _content_type), do: []
  defp build_download_archive_options(%Source{collection_type: :video}, _was_forced, _content_type), do: []
  defp build_download_archive_options(%Source{last_indexed_at: nil}, _was_forced, _content_type), do: []
  defp build_download_archive_options(_source, true, _content_type), do: []

  # The archive is an optimization, so if the file can't be written we index
  # without one rather than passing a bad option to yt-dlp or failing the run.
  defp build_download_archive_options(source, _was_forced, content_type) do
    case create_download_archive_file(source, content_type) do
      {:ok, archive_file} ->
        [:break_on_existing, download_archive: archive_file]

      {:error, err} ->
        Logger.warning("Unable to write download archive file for source ##{source.id}: #{inspect(err)}")

        []
    end
  end

  defp build_single_video_options(%Source{collection_type: :video}), do: [:no_playlist]
  defp build_single_video_options(_source), do: []

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

  # Updates the source after a successful indexing run.
  #
  # We only record `last_indexed_at` here. Download cutoff dates are user-controlled
  # and should remain blank until the user explicitly sets one.
  defp update_source_after_indexing(source) do
    Sources.update_source(source, %{last_indexed_at: DateTime.utc_now()}, run_post_commit_tasks: false)

    maybe_kickoff_metadata_storage_for_missing_images(source)
  end

  defp maybe_kickoff_download_if_pending(%Source{collection_type: :video}, _media_item) do
    # Single-video indexing completes quickly and does a final pending-download sweep.
    # Skipping the early kickoff avoids racing that sweep and enqueueing a duplicate download.
    :ok
  end

  defp maybe_kickoff_download_if_pending(_source, media_item) do
    DownloadingHelpers.kickoff_download_if_pending(media_item)
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
