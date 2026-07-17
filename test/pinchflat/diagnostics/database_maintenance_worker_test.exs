defmodule Pinchflat.Diagnostics.DatabaseMaintenanceWorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.Diagnostics.DatabaseMaintenanceWorker
  alias Pinchflat.JobFixtures.TestJobWorker

  describe "kickoff/0" do
    test "enqueues a manual maintenance job" do
      assert {:ok, %Oban.Job{}} = DatabaseMaintenanceWorker.kickoff()

      assert [job] = all_enqueued(worker: DatabaseMaintenanceWorker)
      assert job.args == %{"manual" => true}
    end

    test "does not enqueue a duplicate job" do
      assert {:ok, _} = DatabaseMaintenanceWorker.kickoff()
      assert {:ok, %Oban.Job{conflict?: true}} = DatabaseMaintenanceWorker.kickoff()

      assert [_] = all_enqueued(worker: DatabaseMaintenanceWorker)
    end
  end

  describe "perform/1 opt-in gate" do
    test "scheduled runs are skipped when the setting is disabled" do
      assert {:cancel, message} = perform_job(DatabaseMaintenanceWorker, %{})
      assert message =~ "Scheduled compaction is turned off"
    end

    test "scheduled runs proceed when the setting is enabled" do
      Settings.set(database_maintenance_enabled: true)
      stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 0} end)

      # Reaching the disk space check proves the gate let the run through
      assert {:error, message} = perform_job(DatabaseMaintenanceWorker, %{})
      assert message =~ "Not enough free disk space"
    end

    test "manual runs proceed even when the setting is disabled" do
      stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 0} end)

      assert {:error, message} = perform_job(DatabaseMaintenanceWorker, %{"manual" => true})
      assert message =~ "Not enough free disk space"
    end
  end

  describe "perform/1 when other jobs are running" do
    test "waits for them to finish before proceeding" do
      stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 0} end)
      {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

      # Flip the executing job to completed shortly after the worker starts
      # waiting, so the wait loop has to take at least one lap
      test_pid = self()

      Task.start(fn ->
        Process.sleep(50)
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
        send(test_pid, :job_completed)
      end)

      # Reaching the (stubbed, failing) disk space check proves the wait ended
      assert {:error, message} = perform_job(DatabaseMaintenanceWorker, %{"manual" => true})
      assert message =~ "Not enough free disk space"
      assert_received :job_completed
    end
  end

  describe "perform/1 when disk space is insufficient" do
    test "fails with a descriptive error instead of vacuuming" do
      stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 0} end)

      assert {:error, message} = perform_job(DatabaseMaintenanceWorker, %{"manual" => true})
      assert message =~ "Not enough free disk space"
    end

    test "fails when free disk space cannot be determined" do
      stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> :error end)

      assert {:error, message} = perform_job(DatabaseMaintenanceWorker, %{"manual" => true})
      assert message =~ "Could not determine free disk space"
    end
  end
end
