defmodule Pinchflat.SlowIndexing.SlowIndexingHelpersTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.TasksFixtures
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: original_level)
    end)

    :ok
  end

  setup do
    {:ok, %{source: source_fixture()}}
  end

  describe "kickoff_indexing_task/3" do
    test "schedules a job" do
      source = source_fixture(index_frequency_minutes: 1)

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source)

      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
    end

    test "schedules a job for the future based on when the source was last indexed" do
      source = source_fixture(index_frequency_minutes: 30, last_indexed_at: now_minus(5, :minutes))

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source)

      [job] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})

      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(), :minute), 25, 1
    end

    test "schedules a job immediately if the source was indexed far in the past" do
      source = source_fixture(index_frequency_minutes: 30, last_indexed_at: now_minus(60, :minutes))

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source)

      [job] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})

      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second), 0, 1
    end

    test "schedules a job immediately if the source has never been indexed" do
      source = source_fixture(index_frequency_minutes: 30, last_indexed_at: nil)

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source)

      [job] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})

      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second), 0, 1
    end

    test "schedules a job immediately if the user is forcing an index" do
      source = source_fixture(index_frequency_minutes: 30, last_indexed_at: now_minus(5, :minutes))

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})

      [job] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})

      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second), 0, 1
    end

    test "creates and attaches a task" do
      source = source_fixture(index_frequency_minutes: 1)

      assert {:ok, %Task{} = task} = SlowIndexingHelpers.kickoff_indexing_task(source)

      assert task.source_id == source.id
    end

    test "deletes any pending media collection tasks for the source" do
      source = source_fixture()
      {:ok, job} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "deletes any executing media collection tasks for the source" do
      source = source_fixture()
      {:ok, job} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)
      Repo.update_all(from(Oban.Job, where: [id: ^task.job_id], update: [set: [state: "executing"]]), [])

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "can be called with additional job arguments" do
      source = source_fixture(index_frequency_minutes: 1)
      job_args = %{"force" => true}

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source, job_args)

      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id, "force" => true})
    end

    test "can be called with additional job options" do
      source = source_fixture(index_frequency_minutes: 1)
      job_opts = [max_attempts: 5]

      assert {:ok, _} = SlowIndexingHelpers.kickoff_indexing_task(source, %{}, job_opts)

      [job] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
      assert job.max_attempts == 5
    end
  end

  describe "delete_indexing_tasks/2" do
    test "deletes slow indexing tasks for the source", %{source: source} do
      {:ok, job} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      _task = task_fixture(source_id: source.id, job_id: job.id)

      assert_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
      assert :ok = SlowIndexingHelpers.delete_indexing_tasks(source)
      refute_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "deletes fast indexing tasks for the source", %{source: source} do
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      _task = task_fixture(source_id: source.id, job_id: job.id)

      assert_enqueued(worker: FastIndexingWorker, args: %{"id" => source.id})
      assert :ok = SlowIndexingHelpers.delete_indexing_tasks(source)
      refute_enqueued(worker: FastIndexingWorker)
    end

    test "doesn't normally delete currently executing tasks", %{source: source} do
      {:ok, job} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      from(Oban.Job, where: [id: ^job.id], update: [set: [state: "executing"]])
      |> Repo.update_all([])

      assert Repo.reload!(task)
      assert :ok = SlowIndexingHelpers.delete_indexing_tasks(source)
      assert Repo.reload!(task)
    end

    test "can optionally delete currently executing tasks", %{source: source} do
      {:ok, job} = Oban.insert(MediaCollectionIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      from(Oban.Job, where: [id: ^job.id], update: [set: [state: "executing"]])
      |> Repo.update_all([])

      assert Repo.reload!(task)
      assert :ok = SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end
  end

  describe "index_and_enqueue_download_for_media_items/2" do
    setup do
      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, source_attributes_return_fixture()}
      end)

      :ok
    end

    test "creates a media_item record for each media ID returned", %{source: source} do
      assert media_items = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert Enum.count(media_items) == 3
      assert ["video1", "video2", "video3"] == Enum.map(media_items, & &1.media_id)
      assert ["Video 1", "Video 2", "Video 3"] == Enum.map(media_items, & &1.title)
      assert ["desc1", "desc2", "desc3"] == Enum.map(media_items, & &1.description)
      assert Enum.all?(media_items, fn mi -> mi.original_url end)
      assert Enum.all?(media_items, fn %MediaItem{} -> true end)
    end

    test "attaches all media_items to the given source", %{source: source} do
      source_id = source.id
      assert media_items = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert Enum.count(media_items) == 3
      assert Enum.all?(media_items, fn %MediaItem{source_id: ^source_id} -> true end)
    end

    test "won't duplicate media_items based on media_id and source", %{source: source} do
      _first_run = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      _duplicate_run = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      media_items = Repo.preload(source, :media_items).media_items
      assert Enum.count(media_items) == 3
    end

    test "can duplicate media_ids for different sources", %{source: source} do
      other_source = source_fixture()

      media_items = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      media_items_other_source = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(other_source)

      assert Enum.count(media_items) == 3
      assert Enum.count(media_items_other_source) == 3

      assert Enum.map(media_items, & &1.media_id) ==
               Enum.map(media_items_other_source, & &1.media_id)
    end

    test "returns a list of media_items", %{source: source} do
      first_run = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      duplicate_run = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      first_ids = Enum.map(first_run, & &1.id)
      duplicate_ids = Enum.map(duplicate_run, & &1.id)

      assert first_ids == duplicate_ids
    end

    test "logs indexing completion and pending enqueue details", %{source: source} do
      log =
        capture_log([level: :info], fn ->
          SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
        end)

      assert log =~ "indexing_completed"
      assert log =~ "source_id=#{source.id}"
      assert log =~ "pending_downloads_enqueued="
    end

    test "updates the source's last_indexed_at field", %{source: source} do
      assert source.last_indexed_at == nil

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      source = Repo.reload!(source)

      assert DateTime.diff(DateTime.utc_now(), source.last_indexed_at) < 2
    end

    test "does not populate download_cutoff_date when it's nil" do
      source = source_fixture(download_cutoff_date: nil)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      source = Repo.reload!(source)

      assert source.download_cutoff_date == nil
    end

    test "does not replace an older download_cutoff_date" do
      old_cutoff = Date.utc_today() |> Date.add(-30)
      source = source_fixture(download_cutoff_date: old_cutoff)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      source = Repo.reload!(source)

      assert source.download_cutoff_date == old_cutoff
    end

    test "does not change download_cutoff_date when it's more recent than 7 days ago" do
      recent_cutoff = Date.utc_today() |> Date.add(-3)
      source = source_fixture(download_cutoff_date: recent_cutoff)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      source = Repo.reload!(source)

      assert source.download_cutoff_date == recent_cutoff
    end

    test "kicks off metadata storage if source images are missing but should be downloaded" do
      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(%{media_profile_id: profile.id, poster_filepath: nil, fanart_filepath: nil})

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert_enqueued(worker: SourceMetadataStorageWorker, args: %{"id" => source.id})
    end

    test "does not kick off metadata storage if source images exist" do
      source = source_with_metadata_attachments()

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      refute_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "does not kick off metadata storage if profile does not download source images" do
      profile = media_profile_fixture(%{download_source_images: false})
      source = source_fixture(%{media_profile_id: profile.id, poster_filepath: nil})

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      refute_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "enqueues a job for each pending media item" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "does not attach tasks if the source is set to not download" do
      source = source_fixture(download_media: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "doesn't blow up if a media item cannot be coerced into a struct", %{source: source} do
      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        response =
          Phoenix.json_library().encode!(%{
            id: "video3",
            title: "Video 3",
            live_status: "not_live",
            description: "desc3",
            # Only focusing on these because these are passed to functions that
            # could fail if they're not present
            original_url: nil,
            aspect_ratio: nil,
            duration: nil,
            upload_date: nil
          })

        {:ok, response}
      end)

      assert [changeset] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert %Ecto.Changeset{} = changeset
    end

    test "doesn't blow up if the media item cannot be saved", %{source: source} do
      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        response =
          Phoenix.json_library().encode!(%{
            id: "video1",
            # This is a disallowed title - see MediaItem changeset or issue #549
            title: "youtube video #123",
            original_url: "https://example.com/video1",
            live_status: "not_live",
            description: "desc1",
            aspect_ratio: 1.67,
            duration: 12.34,
            upload_date: "20210101"
          })

        {:ok, response}
      end)

      assert [changeset] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert %Ecto.Changeset{} = changeset
    end

    test "passes the source's download options to the yt-dlp runner", %{source: source} do
      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        assert {:output, "/tmp/test/media/%(title)S.%(ext)S"} in opts
        assert {:remux_video, "mp4"} in opts
        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end
  end

  describe "index_and_enqueue_download_for_media_items/2 when testing cookies" do
    test "sets use_cookies if the source uses cookies" do
      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert {:use_cookies, true} in addl_opts
        {:ok, source_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :all_operations})

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "sets use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert {:use_cookies, true} in addl_opts
        {:ok, source_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "doesn't set use_cookies if the source doesn't use cookies" do
      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert {:use_cookies, false} in addl_opts
        {:ok, source_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :disabled})

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end
  end

  describe "index_and_enqueue_download_for_media_items/2 when testing file watcher" do
    test "creates a new media item for everything already in the file", %{source: source} do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, source_attributes_return_fixture())

        # Need to add a delay to ensure the file watcher has time to read the file
        :timer.sleep(watcher_poll_interval * 2)
        # We know we're testing the file watcher since the syncronous call will only
        # return an empty string (creating no records)
        {:ok, ""}
      end)

      assert Repo.aggregate(MediaItem, :count, :id) == 0
      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      assert Repo.aggregate(MediaItem, :count, :id) == 3
    end

    test "enqueues a download for everything already in the file", %{source: source} do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, source_attributes_return_fixture())

        # Need to add a delay to ensure the file watcher has time to read the file
        :timer.sleep(watcher_poll_interval * 2)
        # We know we're testing the file watcher since the syncronous call will only
        # return an empty string (creating no records)
        {:ok, ""}
      end)

      refute_enqueued(worker: MediaDownloadWorker)
      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      assert_enqueued(worker: MediaDownloadWorker)
    end

    test "does not enqueue downloads if the source is set to not download" do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)
      source = source_fixture(download_media: false)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, source_attributes_return_fixture())

        # Need to add a delay to ensure the file watcher has time to read the file
        :timer.sleep(watcher_poll_interval * 2)
        # We know we're testing the file watcher since the syncronous call will only
        # return an empty string (creating no records)
        {:ok, ""}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "playlist sources with automatic downloads enabled enqueue downloads after indexing" do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)
      source = source_fixture(%{collection_type: :playlist, selection_mode: :all, download_media: true})

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, source_attributes_return_fixture())

        :timer.sleep(watcher_poll_interval * 2)
        {:ok, ""}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      assert_enqueued(worker: MediaDownloadWorker)
    end

    test "playlist sources in manual selection mode do not enqueue downloads after indexing" do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, source_attributes_return_fixture())

        :timer.sleep(watcher_poll_interval * 2)
        {:ok, ""}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      refute_enqueued(worker: MediaDownloadWorker)
      assert Enum.all?(Repo.all(MediaItem), & &1.prevent_download)
    end

    test "does not enqueue downloads for media that doesn't match the profile's format options" do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)
      profile = media_profile_fixture(%{shorts_behaviour: :exclude})
      source = source_fixture(%{media_profile_id: profile.id})

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)

        contents =
          Phoenix.json_library().encode!(%{
            id: "video2",
            title: "Video 2",
            original_url: "https://example.com/shorts/video2",
            live_status: "is_live",
            description: "desc2",
            aspect_ratio: 1.67,
            duration: 345.67,
            upload_date: "20210101"
          })

        File.write(filepath, contents)

        # Need to add a delay to ensure the file watcher has time to read the file
        :timer.sleep(watcher_poll_interval * 2)
        # We know we're testing the file watcher since the syncronous call will only
        # return an empty string (creating no records)
        {:ok, ""}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not enqueue multiple download jobs for the same media items", %{source: source} do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, source_attributes_return_fixture())

        # Need to add a delay to ensure the file watcher has time to read the file
        :timer.sleep(watcher_poll_interval * 2)
        # This also returns the final result to the yt-dlp call (like the real usage actually would do)
        # so it'll attempt to create the media items and enqueue the download jobs based on this as well
        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      assert Repo.aggregate(MediaItem, :count, :id) == 3
      assert [_, _, _] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "does not blow up if the file returns invalid json", %{source: source} do
      watcher_poll_interval = Application.get_env(:pinchflat, :file_watcher_poll_interval)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        File.write(filepath, "INVALID")

        # Need to add a delay to ensure the file watcher has time to read the file
        :timer.sleep(watcher_poll_interval * 2)
        # We know we're testing the file watcher since the syncronous call will only
        # return an empty string (creating no records)
        {:ok, ""}
      end)

      assert [] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end
  end

  describe "index_and_enqueue_download_for_media_items when testing the download archive" do
    test "a download archive is used if the source is a channel that has been indexed before" do
      source = source_fixture(%{collection_type: :channel, last_indexed_at: now()})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        assert :break_on_existing in opts
        assert Keyword.has_key?(opts, :download_archive)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "a download archive is not used if the source is not a channel" do
      source = source_fixture(%{collection_type: :playlist})

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute :break_on_existing in opts
        refute Keyword.has_key?(opts, :download_archive)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "a download archive is not used if the source has never been indexed before" do
      source = source_fixture(%{collection_type: :channel, last_indexed_at: nil})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute :break_on_existing in opts
        refute Keyword.has_key?(opts, :download_archive)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "a download archive is not used if the index has been forced to run" do
      source = source_fixture(%{collection_type: :channel})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute :break_on_existing in opts
        refute Keyword.has_key?(opts, :download_archive)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source, was_forced: true)
    end

    test "the download archive is formatted correctly and contains the right video" do
      source = source_fixture(%{collection_type: :channel, last_indexed_at: now()})

      media_items =
        1..21
        |> Enum.map(fn n ->
          media_item_fixture(%{source_id: source.id, uploaded_at: now_minus(n, :days)})
        end)

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        archive_file = Keyword.get(opts, :download_archive)
        last_media_item = List.last(media_items)

        if String.ends_with?(url, "/videos") do
          assert File.read!(archive_file) == "youtube #{last_media_item.media_id}"
        else
          # The seeded media items are all regular videos, so the shorts and
          # streams archives have nothing to hold
          assert File.read!(archive_file) == ""
        end

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "each tab's download archive only contains media of that tab's content type" do
      source = source_fixture(%{collection_type: :channel, last_indexed_at: now()})

      [oldest_video, oldest_short, oldest_stream] =
        Enum.map(
          [
            %{short_form_content: false, livestream: false},
            %{short_form_content: true, livestream: false},
            %{short_form_content: false, livestream: true}
          ],
          fn content_attrs ->
            1..21
            |> Enum.map(fn n ->
              media_item_fixture(Map.merge(content_attrs, %{source_id: source.id, uploaded_at: now_minus(n, :days)}))
            end)
            |> List.last()
          end
        )

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        archive_contents = opts |> Keyword.get(:download_archive) |> File.read!()

        expected_media_item =
          case Regex.run(~r{/(videos|shorts|streams)$}, url) do
            [_, "videos"] -> oldest_video
            [_, "shorts"] -> oldest_short
            [_, "streams"] -> oldest_stream
          end

        assert archive_contents == "youtube #{expected_media_item.media_id}"

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end
  end

  describe "index_and_enqueue_download_for_media_items when testing the indexing cutoff date" do
    test "a channel with an indexing cutoff date passes break filters to every tab" do
      source =
        source_fixture(%{
          collection_type: :channel,
          index_cutoff_date: ~D[2026-07-01]
        })

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        break_filters = for {:break_match_filters, filter} <- opts, do: filter

        assert break_filters == ["upload_date >= 20260701", "!upload_date"]

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "the cutoff applies even when the index is forced" do
      source =
        source_fixture(%{
          collection_type: :channel,
          last_indexed_at: now(),
          index_cutoff_date: ~D[2026-07-01]
        })

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        assert Keyword.has_key?(opts, :break_match_filters)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source, was_forced: true)
    end

    test "the cutoff is not applied when the source has no indexing cutoff date" do
      source = source_fixture(%{collection_type: :channel, index_cutoff_date: nil})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute Keyword.has_key?(opts, :break_match_filters)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "the cutoff is not applied to playlists" do
      source = source_fixture(%{collection_type: :playlist, index_cutoff_date: ~D[2026-07-01]})

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute Keyword.has_key?(opts, :break_match_filters)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "the cutoff is not applied to non-YouTube channels" do
      source =
        source_fixture(%{
          collection_type: :channel,
          original_url: "https://example.com/some-channel",
          index_cutoff_date: ~D[2026-07-01]
        })

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute Keyword.has_key?(opts, :break_match_filters)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end
  end

  describe "index_and_enqueue_download_for_media_items/2 when splitting channels into tabs" do
    test "indexes a channel's videos, shorts, and streams tabs separately" do
      source = source_fixture(%{collection_type: :channel})
      base_url = "https://www.youtube.com/channel/#{source.collection_id}"

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        send(self(), {:indexed_url, url})

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

      assert_received {:indexed_url, url_1}
      assert_received {:indexed_url, url_2}
      assert_received {:indexed_url, url_3}

      assert [url_1, url_2, url_3] == Enum.map(~w(videos shorts streams), fn tab -> "#{base_url}/#{tab}" end)
    end

    test "doesn't return duplicate media items if multiple tabs return the same media" do
      source = source_fixture(%{collection_type: :channel})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, source_attributes_return_fixture()}
      end)

      assert media_items = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      assert Enum.count(media_items) == 3
    end

    test "uses the source's URL as-is if it already points at a specific tab" do
      source = source_fixture(%{collection_type: :channel, original_url: "https://www.youtube.com/@foo/videos"})

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        assert url == "https://www.youtube.com/@foo/videos"

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "the archive for an explicit tab URL is filtered to that tab's content type" do
      source =
        source_fixture(%{
          collection_type: :channel,
          last_indexed_at: now(),
          original_url: "https://www.youtube.com/@foo/shorts"
        })

      oldest_short =
        1..21
        |> Enum.map(fn n ->
          media_item_fixture(%{source_id: source.id, short_form_content: true, uploaded_at: now_minus(n, :days)})
        end)
        |> List.last()

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        archive_contents = opts |> Keyword.get(:download_archive) |> File.read!()

        assert archive_contents == "youtube #{oldest_short.media_id}"

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "doesn't split non-YouTube channels into tabs" do
      source = source_fixture(%{collection_type: :channel, original_url: "https://example.com/some-channel"})

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        assert url == "https://example.com/some-channel"

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "doesn't split playlists into tabs" do
      source = source_fixture(%{collection_type: :playlist})

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        assert url == source.original_url

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "still indexes the other tabs if one tab fails" do
      source = source_fixture(%{collection_type: :channel})

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        if String.ends_with?(url, "/shorts") do
          {:error, "This channel does not have a shorts tab", 1}
        else
          {:ok, source_attributes_return_fixture()}
        end
      end)

      assert media_items = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      assert Enum.count(media_items) == 3
    end

    test "fails the indexing run if every tab fails" do
      source = source_fixture(%{collection_type: :channel})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:error, "Something went wrong", 1}
      end)

      assert_raise MatchError, fn ->
        SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
      end
    end
  end

  describe "index_and_enqueue_download_for_media_items/2 when logging tab failures" do
    setup do
      # The test env logger level suppresses everything below :critical,
      # so it needs to be loosened for log output to be capturable
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)
    end

    test "a channel missing a tab is not logged as a failure" do
      source = source_fixture(%{collection_type: :channel})

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert {:expected_exit_codes, [1]} in addl_opts

        if String.ends_with?(url, "/streams") do
          {:error, "ERROR: [youtube:tab] UC123: This channel does not have a streams tab", 1}
        else
          {:ok, source_attributes_return_fixture()}
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
        end)

      refute log =~ "Indexing failed"
    end

    test "other tab failures are logged as warnings" do
      source = source_fixture(%{collection_type: :channel})

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        if String.ends_with?(url, "/streams") do
          {:error, "Something went wrong", 1}
        else
          {:ok, source_attributes_return_fixture()}
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
        end)

      assert log =~ "Indexing failed"
    end
  end

  describe "index_and_enqueue_download_for_media_items when testing dateafter options" do
    test "uses dateafter when download_cutoff_date is set" do
      cutoff_date = Date.utc_today() |> Date.add(-10)
      source = source_fixture(%{download_cutoff_date: cutoff_date})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        expected_dateafter = Date.to_iso8601(cutoff_date, :basic)
        assert {:dateafter, ^expected_dateafter} = Enum.find(opts, fn opt -> match?({:dateafter, _}, opt) end)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "uses retention-based date when retention_period_days is set and more recent than cutoff" do
      # Old cutoff date (30 days ago)
      old_cutoff = Date.utc_today() |> Date.add(-30)
      # Retention of 5 days means we only need to scan ~8 days (5 + 3 buffer)
      source = source_fixture(%{download_cutoff_date: old_cutoff, retention_period_days: 5})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        {:dateafter, dateafter_value} = Enum.find(opts, fn opt -> match?({:dateafter, _}, opt) end)

        # Should be retention + buffer days ago (5 + 3 = 8 days ago)
        expected_date = Date.utc_today() |> Date.add(-8)
        expected_dateafter = Date.to_iso8601(expected_date, :basic)
        assert dateafter_value == expected_dateafter

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "uses cutoff date when it's more recent than retention-based date" do
      # Recent cutoff date (2 days ago)
      recent_cutoff = Date.utc_today() |> Date.add(-2)
      # Retention of 30 days would mean scanning 33 days (30 + 3 buffer)
      source = source_fixture(%{download_cutoff_date: recent_cutoff, retention_period_days: 30})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        expected_dateafter = Date.to_iso8601(recent_cutoff, :basic)
        assert {:dateafter, ^expected_dateafter} = Enum.find(opts, fn opt -> match?({:dateafter, _}, opt) end)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "does not use dateafter when neither cutoff nor retention is set" do
      source = source_fixture(%{download_cutoff_date: nil, retention_period_days: nil})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute Keyword.has_key?(opts, :dateafter)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "does not use dateafter when retention is 0 (keep forever) and no cutoff" do
      source = source_fixture(%{download_cutoff_date: nil, retention_period_days: 0})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        refute Keyword.has_key?(opts, :dateafter)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "uses cutoff date when retention is 0 (keep forever)" do
      cutoff_date = Date.utc_today() |> Date.add(-10)
      source = source_fixture(%{download_cutoff_date: cutoff_date, retention_period_days: 0})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        expected_dateafter = Date.to_iso8601(cutoff_date, :basic)
        assert {:dateafter, ^expected_dateafter} = Enum.find(opts, fn opt -> match?({:dateafter, _}, opt) end)

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end

    test "uses retention-based date when cutoff is nil but retention is set" do
      source = source_fixture(%{download_cutoff_date: nil, retention_period_days: 7})

      expect(YtDlpRunnerMock, :run, 3, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        {:dateafter, dateafter_value} = Enum.find(opts, fn opt -> match?({:dateafter, _}, opt) end)

        # Should be retention + buffer days ago (7 + 3 = 10 days ago)
        expected_date = Date.utc_today() |> Date.add(-10)
        expected_dateafter = Date.to_iso8601(expected_date, :basic)
        assert dateafter_value == expected_dateafter

        {:ok, source_attributes_return_fixture()}
      end)

      SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    end
  end
end
