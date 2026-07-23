defmodule Pinchflat.Reconciliation.ReconcileWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.ReconcilePlan
  alias Pinchflat.Reconciliation.ReconcileWorker

  describe "kickoff_build/2" do
    test "creates a plan and enqueues a build job" do
      assert {:ok, _} = ReconcileWorker.kickoff_build(:local)

      assert [%ReconcilePlan{mode: :local, status: :building, source_id: nil}] = Repo.all(ReconcilePlan)
      assert [_job] = all_enqueued(worker: ReconcileWorker)
    end

    test "links the job to the source via a task when scoped" do
      source = source_fixture()

      assert {:ok, task} = ReconcileWorker.kickoff_build(:local, source)

      assert task.source_id == source.id
      assert [%ReconcilePlan{source_id: source_id}] = Repo.all(ReconcilePlan)
      assert source_id == source.id
    end

    test "deletes the plan when the job is a duplicate" do
      assert {:ok, _} = ReconcileWorker.kickoff_build(:local)
      assert {:error, :duplicate_job} = ReconcileWorker.kickoff_build(:local)

      assert [%ReconcilePlan{}] = Repo.all(ReconcilePlan)
    end

    test "marks older ready plans stale" do
      {:ok, old_plan} = Reconciliation.create_plan(%{mode: :local, status: :ready})

      assert {:ok, _} = ReconcileWorker.kickoff_build(:local)

      assert Repo.reload(old_plan).status == :stale
    end
  end

  describe "kickoff_apply/1" do
    test "refuses to apply a plan that isn't ready" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :building})

      assert {:error, :not_ready} = ReconcileWorker.kickoff_apply(plan)
    end

    test "enqueues an apply job for a ready plan" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :ready})

      assert {:ok, _} = ReconcileWorker.kickoff_apply(plan)
      assert [_job] = all_enqueued(worker: ReconcileWorker)
    end
  end

  describe "perform/1 (build)" do
    test "builds the plan and marks it ready" do
      source = source_fixture()
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, source_id: source.id, status: :building})

      assert :ok = perform_job(ReconcileWorker, %{"op" => "build", "plan_id" => plan.id})

      assert Repo.reload(plan).status == :ready
    end
  end

  describe "perform/1 (apply)" do
    test "applies a ready plan" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :ready})

      assert :ok = perform_job(ReconcileWorker, %{"op" => "apply", "plan_id" => plan.id})

      assert Repo.reload(plan).status == :applied
    end

    test "cancels when the plan is not ready" do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :stale})

      assert {:cancel, message} = perform_job(ReconcileWorker, %{"op" => "apply", "plan_id" => plan.id})
      assert message =~ "only a ready plan can be applied"
    end
  end
end
