defmodule Pinchflat.Diagnostics.QueueDiagnosticsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Tasks
  alias Pinchflat.Diagnostics.QueueDiagnostics
  alias Pinchflat.JobFixtures.TestJobWorker
  alias Pinchflat.FastIndexing.FastIndexingWorker

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

<<<<<<< HEAD
=======
  describe "queue_names/0" do
    test "returns the queue names from the Oban config" do
      assert :default in QueueDiagnostics.queue_names()
      assert :media_fetching in QueueDiagnostics.queue_names()
    end

    test "returns an empty list when no queues are configured" do
      original = Application.get_env(:pinchflat, Oban, [])
      on_exit(fn -> Application.put_env(:pinchflat, Oban, original) end)

      Application.put_env(:pinchflat, Oban, Keyword.delete(original, :queues))

      assert QueueDiagnostics.queue_names() == []
    end
  end

  describe "get_all_queue_stats/0" do
    test "returns an entry per configured queue without crashing when queues aren't running" do
      stats = QueueDiagnostics.get_all_queue_stats()

      assert length(stats) == length(QueueDiagnostics.queue_names())
      assert %{name: :default, running: 0, limit: 0, paused: false} = Enum.find(stats, &(&1.name == :default))
    end

    test "counts jobs in the queue by state" do
      {:ok, _available} = Oban.insert(TestJobWorker.new(%{"id" => 1}))
      {:ok, _also_available} = Oban.insert(TestJobWorker.new(%{"id" => 2}))
      {:ok, retryable} = Oban.insert(TestJobWorker.new(%{"id" => 3}))
      set_job_state(retryable, "retryable")

      default_stats = Enum.find(QueueDiagnostics.get_all_queue_stats(), &(&1.name == :default))

      assert %{available: 2, retryable: 1, scheduled: 0, executing: 0} = default_stats
    end
  end

  describe "get_retryable_jobs/1" do
    test "returns only retryable jobs" do
      {:ok, retryable} = Oban.insert(TestJobWorker.new(%{"id" => 1}))
      {:ok, _available} = Oban.insert(TestJobWorker.new(%{"id" => 2}))
      set_job_state(retryable, "retryable")

      assert [%{id: id, args: %{"id" => 1}, state: "retryable"}] = QueueDiagnostics.get_retryable_jobs()
      assert id == retryable.id
    end

    test "orders jobs by most recently attempted first" do
      {:ok, older} = Oban.insert(TestJobWorker.new(%{}))
      {:ok, newer} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(older, "retryable", attempted_at: hours_ago(2))
      set_job_state(newer, "retryable", attempted_at: hours_ago(1))

      assert [%{id: first}, %{id: second}] = QueueDiagnostics.get_retryable_jobs()
      assert first == newer.id
      assert second == older.id
    end

    test "respects the limit" do
      Enum.each(1..3, fn _ ->
        {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
        set_job_state(job, "retryable")
      end)

      assert length(QueueDiagnostics.get_retryable_jobs(2)) == 2
    end
  end

  describe "get_discarded_jobs/1" do
    test "returns only discarded jobs" do
      {:ok, discarded} = Oban.insert(TestJobWorker.new(%{"id" => 1}))
      {:ok, _available} = Oban.insert(TestJobWorker.new(%{"id" => 2}))
      set_job_state(discarded, "discarded")

      assert [%{id: id, args: %{"id" => 1}, state: "discarded"}] = QueueDiagnostics.get_discarded_jobs()
      assert id == discarded.id
    end

    test "orders jobs by most recently discarded first" do
      {:ok, older} = Oban.insert(TestJobWorker.new(%{}))
      {:ok, newer} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(older, "discarded", discarded_at: hours_ago(2))
      set_job_state(newer, "discarded", discarded_at: hours_ago(1))

      assert [%{id: first}, %{id: second}] = QueueDiagnostics.get_discarded_jobs()
      assert first == newer.id
      assert second == older.id
    end

    test "respects the limit" do
      Enum.each(1..3, fn _ ->
        {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
        set_job_state(job, "discarded")
      end)

      assert length(QueueDiagnostics.get_discarded_jobs(2)) == 2
    end
  end

  describe "get_stuck_jobs/1" do
    test "returns executing jobs older than the threshold" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "executing", attempted_at: hours_ago(1))

      assert [%{id: id}] = QueueDiagnostics.get_stuck_jobs(30)
      assert id == job.id
    end

    test "does not return executing jobs within the threshold" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "executing", attempted_at: DateTime.utc_now())

      assert QueueDiagnostics.get_stuck_jobs(30) == []
    end

    test "does not return non-executing jobs no matter how old" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "retryable", attempted_at: hours_ago(10))

      assert QueueDiagnostics.get_stuck_jobs(30) == []
    end
  end

  describe "reset_retryable_jobs/0" do
    test "makes retryable jobs available again and returns the count" do
      {:ok, job_one} = Oban.insert(TestJobWorker.new(%{"id" => 1}))
      {:ok, job_two} = Oban.insert(TestJobWorker.new(%{"id" => 2}))
      set_job_state(job_one, "retryable", attempt: 3, errors: [%{"error" => "boom"}])
      set_job_state(job_two, "retryable")

      assert QueueDiagnostics.reset_retryable_jobs() == 2

      assert %{state: "available", attempt: 1, errors: []} = Repo.get(Oban.Job, job_one.id)
      assert %{state: "available"} = Repo.get(Oban.Job, job_two.id)
    end

    test "does not touch jobs in other states" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "discarded")

      assert QueueDiagnostics.reset_retryable_jobs() == 0
      assert %{state: "discarded"} = Repo.get(Oban.Job, job.id)
    end
  end

  describe "reset_job/1" do
    test "resets a retryable job" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "retryable", attempt: 5, errors: [%{"error" => "boom"}])

      assert QueueDiagnostics.reset_job(job.id) == 1
      assert %{state: "available", attempt: 1, errors: []} = Repo.get(Oban.Job, job.id)
    end

    test "resets a discarded job" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "discarded")

      assert QueueDiagnostics.reset_job(job.id) == 1
      assert %{state: "available"} = Repo.get(Oban.Job, job.id)
    end

    test "refuses to reset an executing job to prevent double execution" do
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      set_job_state(job, "executing")

      assert QueueDiagnostics.reset_job(job.id) == 0
      assert %{state: "executing"} = Repo.get(Oban.Job, job.id)
    end

    test "returns 0 when the job does not exist" do
      assert QueueDiagnostics.reset_job(-1) == 0
    end
  end

  describe "get_system_stats/0" do
    test "counts pending and downloaded media items separately" do
      source = source_fixture()
      _pending = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      _downloaded = media_item_fixture(%{source_id: source.id})

      stats = QueueDiagnostics.get_system_stats()

      assert stats.total_pending_downloads == 1
      assert stats.total_downloaded == 1
    end

    test "excludes media that the profile's rules would never download from the pending count" do
      source = source_fixture(title_filter_regex: "^Keep")
      _matching = media_item_fixture(%{source_id: source.id, media_filepath: nil, title: "Keep me"})
      _filtered = media_item_fixture(%{source_id: source.id, media_filepath: nil, title: "Skip me"})

      assert QueueDiagnostics.get_system_stats().total_pending_downloads == 1
    end

    test "counts sources" do
      source_fixture()
      source_fixture()

      assert QueueDiagnostics.get_system_stats().total_sources == 2
    end

    test "counts all media items regardless of state" do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_filepath: nil})
      media_item_fixture(%{source_id: source.id})

      assert QueueDiagnostics.get_system_stats().total_media_items == 2
    end
  end

  defp set_job_state(job, state, extra_fields \\ []) do
    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [{:state, state} | extra_fields]
    )
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours * 60 * 60, :second)
  end

>>>>>>> ee741db (feat: add database insights and safe compaction maintenance to the diagnostics page)
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
