defmodule Pinchflat.Diagnostics.QueueDiagnosticsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Tasks
  alias Pinchflat.Diagnostics.QueueDiagnostics
  alias Pinchflat.JobFixtures.TestJobWorker
  alias Pinchflat.FastIndexing.FastIndexingWorker

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  describe "get_jobs_for_queue/2" do
    test "returns jobs sitting in the given queue" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{"id" => 42}))

      jobs = QueueDiagnostics.get_jobs_for_queue(:default)

      assert [%{id: id, args: %{"id" => 42}}] = jobs
      assert id == job.id
    end

    test "does not return jobs from other queues" do
      {:ok, _job} = Oban.insert(TestJobWorker.new(%{}))

      assert QueueDiagnostics.get_jobs_for_queue(:some_other_queue) == []
    end

    test "orders executing jobs ahead of available ones" do
      {:ok, available} = Oban.insert(TestJobWorker.new(%{}))
      {:ok, executing} = Oban.insert(TestJobWorker.new(%{}))

      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^executing.id),
        set: [state: "executing"]
      )

      assert [%{id: first}, %{id: second}] = QueueDiagnostics.get_jobs_for_queue(:default)
      assert first == executing.id
      assert second == available.id
    end

    test "respects the limit" do
      Enum.each(1..3, fn _ -> Oban.insert(TestJobWorker.new(%{})) end)

      assert length(QueueDiagnostics.get_jobs_for_queue(:default, 2)) == 2
    end
  end

  describe "describe_job/2" do
    test "resolves a media item from a download worker's args" do
      source = source_fixture(custom_name: "My Channel")
      media_item = media_item_fixture(source_id: source.id, title: "Cool Video")

      assert %{type: :media_item, id: id, source_id: source_id, name: "Cool Video"} =
               QueueDiagnostics.describe_job("Pinchflat.Downloading.MediaDownloadWorker", %{"id" => media_item.id})

      assert id == media_item.id
      assert source_id == source.id
    end

    test "resolves a source from an indexing worker's args" do
      source = source_fixture(custom_name: "My Channel")

      assert %{type: :source, id: id, name: "My Channel"} =
               QueueDiagnostics.describe_job("Pinchflat.FastIndexing.FastIndexingWorker", %{"id" => source.id})

      assert id == source.id
    end

    test "returns a nil name when the target record was deleted" do
      assert %{type: :media_item, id: 999_999, name: nil} =
               QueueDiagnostics.describe_job("Pinchflat.Downloading.MediaDownloadWorker", %{"id" => 999_999})
    end

    test "returns nil for workers without a resolvable target" do
      assert QueueDiagnostics.describe_job("Pinchflat.YtDlp.UpdateWorker", %{}) == nil
    end
  end

  describe "requeue_job/1" do
    test "cancels the original job and enqueues a fresh copy of it" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{"id" => 7}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

      assert {:ok, :requeued} = QueueDiagnostics.requeue_job(job.id)

      assert %{state: "cancelled"} = Repo.get(Oban.Job, job.id)

      assert [new_job] = Repo.all(from(j in Oban.Job, where: j.id != ^job.id))
      assert new_job.args == %{"id" => 7}
      assert new_job.state == "available"
    end

    test "re-links the requeued job to a Task when it targets a source" do
      source = source_fixture()
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))

      assert {:ok, :requeued} = QueueDiagnostics.requeue_job(job.id)

      assert [task] = Tasks.list_tasks_for(source, "FastIndexingWorker", [:available, :scheduled])
      refute task.job_id == job.id
    end

    test "still requeues when the target record no longer exists" do
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => 999_999}))

      assert {:ok, :requeued} = QueueDiagnostics.requeue_job(job.id)
      assert %{state: "cancelled"} = Repo.get(Oban.Job, job.id)
    end

    test "returns an error when the job does not exist" do
      assert {:error, :not_found} = QueueDiagnostics.requeue_job(-1)
    end
  end

  describe "delete_discarded_job/1" do
    test "deletes a discarded job" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

      assert {:ok, :deleted} = QueueDiagnostics.delete_discarded_job(job.id)
      assert Repo.get(Oban.Job, job.id) == nil
    end

    test "does not delete a non-discarded job" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))

      assert {:error, :not_found} = QueueDiagnostics.delete_discarded_job(job.id)
      assert Repo.get(Oban.Job, job.id)
    end

    test "returns an error when the job does not exist" do
      assert {:error, :not_found} = QueueDiagnostics.delete_discarded_job(-1)
    end
  end
end
