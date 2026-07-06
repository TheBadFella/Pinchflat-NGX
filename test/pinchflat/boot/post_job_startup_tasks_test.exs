defmodule Pinchflat.Boot.PostJobStartupTasksTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Boot.PostJobStartupTasks
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  describe "reschedule_missing_indexing_tasks (slow indexing)" do
    test "schedules an indexing job for a source that has none" do
      source = source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)

      PostJobStartupTasks.init(%{})

      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args["id"] == source.id
    end

    test "does not schedule a duplicate job if one already exists" do
      source = source_fixture()
      MediaCollectionIndexingWorker.kickoff_with_task(source)

      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)

      PostJobStartupTasks.init(%{})

      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "does not schedule a job for disabled sources" do
      source_fixture(enabled: false)

      PostJobStartupTasks.init(%{})

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "does not schedule a job for sources marked for deletion" do
      source_fixture(marked_for_deletion_at: DateTime.utc_now())

      PostJobStartupTasks.init(%{})

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "does not schedule a job for sources that don't index" do
      source_fixture(index_frequency_minutes: 0)

      PostJobStartupTasks.init(%{})

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end
  end

  describe "reschedule_missing_indexing_tasks (fast indexing)" do
    test "schedules a fast indexing job for a fast-index source that has none" do
      source = source_fixture(fast_index: true)

      assert [] = all_enqueued(worker: FastIndexingWorker)

      PostJobStartupTasks.init(%{})

      assert [job] = all_enqueued(worker: FastIndexingWorker)
      assert job.args["id"] == source.id
    end

    test "does not schedule a duplicate job if one already exists" do
      source = source_fixture(fast_index: true)
      FastIndexingWorker.kickoff_with_task(source)

      assert [_] = all_enqueued(worker: FastIndexingWorker)

      PostJobStartupTasks.init(%{})

      assert [_] = all_enqueued(worker: FastIndexingWorker)
    end

    test "does not schedule a job for sources without fast indexing" do
      source_fixture(fast_index: false)

      PostJobStartupTasks.init(%{})

      assert [] = all_enqueued(worker: FastIndexingWorker)
    end

    test "does not schedule a job for disabled sources" do
      source_fixture(fast_index: true, enabled: false)

      PostJobStartupTasks.init(%{})

      assert [] = all_enqueued(worker: FastIndexingWorker)
    end
  end
end
