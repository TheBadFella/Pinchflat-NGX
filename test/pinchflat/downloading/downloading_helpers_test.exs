defmodule Pinchflat.Downloading.DownloadingHelpersTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Tasks
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.MediaDownloadWorker

  describe "enqueue_pending_download_tasks/1" do
    test "enqueues a job for each pending media item" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert 1 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "does not enqueue a job for media items with a filepath" do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id, media_filepath: "some/filepath.mp4")

      assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "attaches a task to each enqueued job" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert [] = Tasks.list_tasks_for(media_item)

      assert 1 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert [_] = Tasks.list_tasks_for(media_item)
    end

    test "does not create a job if the source is set to not download" do
      source = source_fixture(download_media: false)

      assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not attach tasks if the source is set to not download" do
      source = source_fixture(download_media: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "can pass job options" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert 1 = DownloadingHelpers.enqueue_pending_download_tasks(source, priority: 1)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id}, priority: 1)
    end

    test "returns 0 when every pending item already has an active job" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)
      queued_before = all_enqueued(worker: MediaDownloadWorker)

      assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert all_enqueued(worker: MediaDownloadWorker) == queued_before
      assert Repo.get!(Pinchflat.Tasks.Task, task.id).job_id == task.job_id
    end

    test "counts only newly scheduled jobs in a mixed batch" do
      source = source_fixture()
      duplicate = media_item_fixture(source_id: source.id, media_filepath: nil)
      assert {:ok, _task} = MediaDownloadWorker.kickoff_with_task(duplicate)

      fresh = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert 1 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => fresh.id})
      assert [_existing] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => duplicate.id})
    end

    test "reports active items in the already_queued count instead of dropping them from the batch" do
      source = source_fixture()
      active = media_item_fixture(source_id: source.id, media_filepath: nil)
      assert {:ok, _task} = MediaDownloadWorker.kickoff_with_task(active)
      fresh = media_item_fixture(source_id: source.id, media_filepath: nil)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert 1 = DownloadingHelpers.enqueue_pending_download_tasks(source)
          end)
        end)

      assert log =~ "pending_download_enqueue source_id=#{source.id} pending_count=2"
      assert log =~ "enqueued=1 already_queued=1 failed=0"
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => fresh.id})
      assert [_existing] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => active.id})
    end

    test "reports an active job created between the lookup and its kickoff as already_queued" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      parent = self()
      handler = "enqueue-lookup-race-#{System.unique_integer([:positive])}"

      # The active-job lookup is the only query joining tasks and oban_jobs by
      # media_item_id before the kickoff. Inserting a job as that query returns
      # leaves the pre-filter empty, so the kickoff transaction must catch it.
      :telemetry.attach(
        handler,
        [:pinchflat, :repo, :query],
        fn _event, _measurements, metadata, {handler, parent, media_item} ->
          query = metadata.query

          if is_binary(query) and String.contains?(query, "oban_jobs") and
               String.contains?(query, "media_item_id") do
            :telemetry.detach(handler)
            {:ok, _task} = MediaDownloadWorker.kickoff_with_task(media_item)
            send(parent, :active_job_created)
          end
        end,
        {handler, parent, media_item}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)
          end)
        end)

      assert_received :active_job_created
      assert log =~ "pending_count=1 enqueued=0 already_queued=1 failed=0"
      assert [_job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "does not filter items whose previous job completed, was discarded or was cancelled" do
      source = source_fixture()

      for state <- ~w(completed discarded cancelled) do
        media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
        assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

        from(j in Oban.Job, where: j.id == ^task.job_id)
        |> Repo.update_all(set: [state: state])
      end

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert 3 = DownloadingHelpers.enqueue_pending_download_tasks(source)
          end)
        end)

      assert log =~ "pending_count=3 enqueued=3 already_queued=0 failed=0"
      assert Repo.aggregate(Oban.Job, :count) == 6
    end

    test "reports failed kickoffs without counting them and without persisting work" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source, priority: -1)
          end)
        end)

      assert log =~ "enqueued=0 already_queued=0 failed=1"
      refute_enqueued(worker: MediaDownloadWorker)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "leaves existing jobs intact in every active uniqueness state" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      for state <- ~w(available scheduled retryable executing suspended) do
        Repo.get!(Oban.Job, task.job_id)
        |> Ecto.Changeset.change(%{state: state})
        |> Repo.update!()

        job_before = Repo.get!(Oban.Job, task.job_id)

        assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)

        job = Repo.get!(Oban.Job, task.job_id)
        assert job.state == state
        assert job.attempt == job_before.attempt
        assert job.args == %{"id" => media_item.id}
        assert job.scheduled_at == job_before.scheduled_at
        assert [persisted] = Tasks.list_tasks_for(media_item)
        assert persisted.id == task.id
        assert persisted.job_id == task.job_id
        assert Repo.aggregate(Oban.Job, :count) == 1
      end
    end

    test "returns 0 and skips enqueue without creating jobs or tasks when downloads are disabled for a source" do
      source = source_fixture(download_media: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)
          end)
        end)

      assert log =~ "reason=source_downloads_disabled"
      refute log =~ "pending_download_enqueue source_id=#{source.id} pending_count"
      refute_enqueued(worker: MediaDownloadWorker)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "enqueues from id-only projections and counts only newly scheduled jobs" do
      source = source_fixture()
      description = String.duplicate("wide description ", 1_000)
      first = media_item_fixture(source_id: source.id, media_filepath: nil, description: description)
      second = media_item_fixture(source_id: source.id, media_filepath: nil, description: description)
      already_queued = media_item_fixture(source_id: source.id, media_filepath: nil, description: description)
      assert {:ok, existing_task} = MediaDownloadWorker.kickoff_with_task(already_queued)

      assert 2 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => first.id})
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => second.id})
      assert [existing_job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => already_queued.id})
      assert existing_job.id == existing_task.job_id
      assert Repo.aggregate(Oban.Job, :count) == 3

      assert [first_task] = Tasks.list_tasks_for(first)
      assert [second_task] = Tasks.list_tasks_for(second)
      assert first_task.job_id != second_task.job_id
      assert [persisted] = Tasks.list_tasks_for(already_queued)
      assert persisted.id == existing_task.id
    end

    test "the enqueue projection loads only the id while full-row callers keep every field" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil, description: "a long description")

      assert [projected] = Media.list_pending_media_items_for_enqueue(source)
      assert %Pinchflat.Media.MediaItem{} = projected
      assert projected.id == media_item.id
      assert is_nil(projected.title)
      assert is_nil(projected.description)

      assert [full] = Media.list_pending_media_items_for(source)
      assert full.id == media_item.id
      assert full.title == media_item.title
      assert full.description == "a long description"
    end
  end

  describe "retry_pending_download_tasks/1" do
    test "returns :downloads_disabled when downloads are disabled on the source" do
      source = source_fixture(download_media: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert :downloads_disabled = DownloadingHelpers.retry_pending_download_tasks(source)
      refute_enqueued(worker: MediaDownloadWorker)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "replaces existing non-executing pending tasks with new jobs" do
      source = source_fixture(download_media: true)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert {:ok, initial_task} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert [initial_task.id] == Enum.map(Tasks.list_tasks_for(media_item), & &1.id)

      assert [{:ok, new_task}] = DownloadingHelpers.retry_pending_download_tasks(source)
      assert new_task.id != initial_task.id
      assert [persisted] = Tasks.list_tasks_for(media_item)
      assert persisted.id == new_task.id
    end

    test "still replaces a queued job that automatic enqueue would skip" do
      source = source_fixture(download_media: true)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert {:ok, initial_task} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert 0 = DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert [{:ok, new_task}] = DownloadingHelpers.retry_pending_download_tasks(source)
      assert new_task.id != initial_task.id
      assert [persisted] = Tasks.list_tasks_for(media_item)
      assert persisted.id == new_task.id
      assert Repo.get!(Oban.Job, initial_task.job_id).state == "cancelled"
    end

    test "returns duplicate error when pending download task is currently executing" do
      source = source_fixture(download_media: true)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      # Oban's uniqueness key includes args, so the executing job must carry the
      # same `reset_last_error` arg the retry path uses to be a real conflict.
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item, %{"reset_last_error" => true})
      job = Repo.get!(Oban.Job, task.job_id)
      job |> Ecto.Changeset.change(%{state: "executing"}) |> Repo.update!()

      assert [{:error, :duplicate_job}] = DownloadingHelpers.retry_pending_download_tasks(source)
      assert [persisted] = Tasks.list_tasks_for(media_item)
      assert persisted.id == task.id
      assert Repo.get!(Oban.Job, task.job_id).state == "executing"
    end
  end

  describe "dequeue_pending_download_tasks/1" do
    test "deletes all pending tasks for a source's media items" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      DownloadingHelpers.enqueue_pending_download_tasks(source)
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert 1 = DownloadingHelpers.dequeue_pending_download_tasks(source)

      refute_enqueued(worker: MediaDownloadWorker)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "preserves executing replacements unless explicitly included and keeps other workers" do
      source = source_fixture()
      item = media_item_fixture(source_id: source.id, media_filepath: "/existing/video.mp4")
      {:ok, download} = MediaDownloadWorker.kickoff_with_task(item, %{force: true})
      job = Pinchflat.Repo.get!(Oban.Job, download.job_id)
      job |> Ecto.Changeset.change(%{state: "executing"}) |> Pinchflat.Repo.update!()

      {:ok, metadata} =
        %{}
        |> Oban.Job.new(worker: Pinchflat.Metadata.SourceMetadataStorageWorker)
        |> Tasks.create_job_with_task(item)

      assert 0 == DownloadingHelpers.dequeue_pending_download_tasks(source)
      assert Pinchflat.Repo.get!(Oban.Job, download.job_id).state == "executing"
      assert 1 == DownloadingHelpers.dequeue_pending_download_tasks(source, include_executing: true)
      assert Pinchflat.Repo.get!(Oban.Job, download.job_id).state == "cancelled"
      assert Pinchflat.Repo.get!(Oban.Job, metadata.job_id).state == "available"
    end
  end

  describe "kickoff_download_if_pending/1" do
    setup do
      media_item = media_item_fixture(media_filepath: nil)

      {:ok, media_item: media_item}
    end

    test "enqueues a download job", %{media_item: media_item} do
      assert {:ok, _} = DownloadingHelpers.kickoff_download_if_pending(media_item)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "creates and returns a download task record", %{media_item: media_item} do
      assert {:ok, task} = DownloadingHelpers.kickoff_download_if_pending(media_item)

      assert [found_task] = Tasks.list_tasks_for(media_item, "MediaDownloadWorker")
      assert task.id == found_task.id
    end

    test "does not enqueue a download job if the source does not allow it" do
      source = source_fixture(%{download_media: false})
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert {:error, :should_not_download} = DownloadingHelpers.kickoff_download_if_pending(media_item)
          end)
        end)

      assert log =~ "reason=source_downloads_disabled"
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "logs media_not_pending when the media item is not pending" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: "some/filepath.mp4")

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert {:error, :should_not_download} = DownloadingHelpers.kickoff_download_if_pending(media_item)
          end)
        end)

      assert log =~ "reason=media_not_pending"
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not enqueue a download job when the availability policy blocks it" do
      source = source_fixture(%{download_public_media: false})
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil, availability: :public)

      assert {:error, :should_not_download} = DownloadingHelpers.kickoff_download_if_pending(media_item)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not enqueue a download job if the media item does not match the format rules" do
      profile = media_profile_fixture(%{livestream_behaviour: :exclude})
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil, livestream: true)

      assert {:error, :should_not_download} = DownloadingHelpers.kickoff_download_if_pending(media_item)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "can pass job options" do
      media_item = media_item_fixture(media_filepath: nil)

      assert {:ok, _} = DownloadingHelpers.kickoff_download_if_pending(media_item, priority: 1)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id}, priority: 1)
    end

    test "re-enables policy-blocked media without clearing manual prevention" do
      source = source_fixture(%{download_public_media: false})
      policy_blocked = media_item_fixture(source_id: source.id, media_filepath: nil, availability: :public)

      manually_prevented =
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          availability: :public,
          prevent_download: true,
          download_prevented_reason: :manual
        )

      assert {:ok, _} = Media.reconcile_availability_policy(source, policy_blocked)
      assert Repo.reload!(policy_blocked).download_prevented_reason == :policy

      assert {:ok, _source} = Sources.update_source(source, %{download_public_media: true})

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => policy_blocked.id})
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => manually_prevented.id})
      assert Repo.reload!(manually_prevented).prevent_download
      assert Repo.reload!(manually_prevented).download_prevented_reason == :manual
      refute Repo.reload!(policy_blocked).prevent_download
      assert Repo.reload!(policy_blocked).download_prevented_reason == nil
    end
  end

  describe "kickoff_redownload_for_existing_media/1" do
    test "enqueues a download job for each downloaded media item" do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: "some/filepath.mp4")

      assert [{:ok, _}] = DownloadingHelpers.kickoff_redownload_for_existing_media(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id, "force" => true})
    end

    test "doesn't enqueue jobs for media that should be ignored" do
      source = source_fixture()
      other_source = source_fixture()
      _not_downloaded = media_item_fixture(source_id: source.id, media_filepath: nil)
      _other_source = media_item_fixture(source_id: other_source.id, media_filepath: "some/filepath.mp4")

      _download_prevented =
        media_item_fixture(source_id: source.id, media_filepath: "some/filepath.mp4", prevent_download: true)

      assert [] = DownloadingHelpers.kickoff_redownload_for_existing_media(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end
  end

  describe "retry_failed_download_tasks/0" do
    test "retries transient failures without forcing permanent failures" do
      transient =
        media_item_fixture(
          media_filepath: nil,
          last_error: "Network is unreachable",
          error_type: :transient
        )

      permanent =
        media_item_fixture(
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: :error,
          last_error: "Video unavailable",
          error_type: :permanent
        )

      assert [{:ok, _task}] = DownloadingHelpers.retry_failed_download_tasks()
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => transient.id, "reset_last_error" => true})
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => permanent.id})
    end
  end

  describe "force_retry_permanent_download_tasks/1" do
    test "force retries permanent failures and leaves transient failures alone" do
      transient =
        media_item_fixture(
          media_filepath: nil,
          last_error: "Network is unreachable",
          error_type: :transient
        )

      permanent =
        media_item_fixture(
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: :error,
          last_error: "Video unavailable",
          error_type: :permanent
        )

      assert [{:ok, _task}] = DownloadingHelpers.force_retry_permanent_download_tasks()

      assert_enqueued(
        worker: MediaDownloadWorker,
        args: %{"id" => permanent.id, "force" => true, "reset_last_error" => true}
      )

      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => transient.id})
    end

    test "does not retry permanent errors that are not download-prevented" do
      media_item =
        media_item_fixture(
          media_filepath: nil,
          prevent_download: false,
          last_error: "Video unavailable",
          error_type: :permanent
        )

      assert [] = DownloadingHelpers.force_retry_permanent_download_tasks()

      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "scopes the retry to the given source" do
      source = source_fixture()
      other_source = source_fixture()

      scoped =
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: :error,
          last_error: "Video unavailable",
          error_type: :permanent
        )

      other =
        media_item_fixture(
          source_id: other_source.id,
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: :error,
          last_error: "Video unavailable",
          error_type: :permanent
        )

      assert [{:ok, _task}] = DownloadingHelpers.force_retry_permanent_download_tasks(source)

      assert_enqueued(
        worker: MediaDownloadWorker,
        args: %{"id" => scoped.id, "force" => true, "reset_last_error" => true}
      )

      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => other.id})
    end
  end

  defp with_debug_logs(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end
end
