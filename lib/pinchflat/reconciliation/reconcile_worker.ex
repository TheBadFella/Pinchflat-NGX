defmodule Pinchflat.Reconciliation.ReconcileWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    # Dedupe on worker alone (not args) so a build and an apply can't run
    # alongside each other — either would invalidate the other's view of disk
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :queue]],
    max_attempts: 1,
    tags: ["local_data", "reconciliation", "show_in_dashboard"]

  import Ecto.Query, warn: false

  require Logger

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.PlanBuilder
  alias Pinchflat.Reconciliation.PlanApplier
  alias Pinchflat.Diagnostics.QueueDiagnostics

  @doc """
  Enqueues a dry-run plan build. Any still-reviewable older plans are marked
  stale first — only the newest plan can be applied. When scoped to a source,
  the job is linked to it via a Task so it shows in the source's task list.

  Returns {:ok, %Oban.Job{} | %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_build(mode, source \\ nil) do
    Reconciliation.mark_ready_plans_stale()

    {:ok, plan} =
      Reconciliation.create_plan(%{
        mode: mode,
        source_id: source && source.id,
        status: :building
      })

    args = %{"op" => "build", "plan_id" => plan.id}

    result =
      if source do
        args |> ReconcileWorker.new() |> Tasks.create_job_with_task(source)
      else
        Repo.insert_unique_job(ReconcileWorker.new(args))
      end

    # A deduped/failed insert would otherwise strand the plan in `building`
    case result do
      {:ok, _} -> result
      {:duplicate, _job} -> handle_failed_insert(plan, {:error, :duplicate_job})
      err -> handle_failed_insert(plan, err)
    end
  end

  defp handle_failed_insert(plan, err) do
    Repo.delete(plan)
    err
  end

  @doc """
  Enqueues the apply run for a reviewed (ready) plan.

  Returns {:ok, %Oban.Job{} | %Task{}} | {:error, :duplicate_job | :not_ready} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_apply(plan) do
    if plan.status == :ready do
      args = %{"op" => "apply", "plan_id" => plan.id}
      source = plan.source_id && Sources.get_source!(plan.source_id)

      result =
        if source do
          args |> ReconcileWorker.new() |> Tasks.create_job_with_task(source)
        else
          Repo.insert_unique_job(ReconcileWorker.new(args))
        end

      case result do
        {:duplicate, _job} -> {:error, :duplicate_job}
        other -> other
      end
    else
      {:error, :not_ready}
    end
  end

  @doc """
  Builds a plan's items (the dry run — read-only on the filesystem) or applies
  a reviewed plan. Applying reserves a quiet window first: all job queues are
  paused and the worker waits for other executing jobs to finish, so nothing
  can race the file moves and `*_filepath` column updates. Queues are resumed
  in an `after` block, and pause state is in-memory so a crash can't leave
  them stuck paused.

  Returns :ok | {:cancel, binary()} | {:error, any()}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "build", "plan_id" => plan_id}}) do
    plan = Reconciliation.get_plan!(plan_id)

    case PlanBuilder.build_plan_items(plan) do
      {:ok, built_plan} ->
        {:ok, _} = Reconciliation.update_plan(built_plan, %{status: :ready})
        :ok

      err ->
        {:ok, _} = Reconciliation.update_plan(plan, %{status: :failed, error_message: inspect(err)})
        {:error, err}
    end
  rescue
    exception ->
      record_plan_failure(plan_id, exception, __STACKTRACE__)
  end

  def perform(%Oban.Job{args: %{"op" => "apply", "plan_id" => plan_id}, id: job_id}) do
    plan = Reconciliation.get_plan!(plan_id)

    if plan.status == :ready do
      {:ok, _} = Reconciliation.update_plan(plan, %{status: :applying})

      with_paused_queues(fn ->
        wait_for_other_running_jobs(job_id)
        {:ok, _} = PlanApplier.apply_plan(plan)
      end)

      :ok
    else
      {:cancel, "Plan ##{plan_id} is #{plan.status} — only a ready plan can be applied"}
    end
  rescue
    exception ->
      record_plan_failure(plan_id, exception, __STACKTRACE__)
  end

  defp record_plan_failure(plan_id, exception, stacktrace) do
    message = Exception.message(exception)
    Logger.error("Reconcile failed for plan ##{plan_id}: #{Exception.format(:error, exception, stacktrace)}")

    plan = Repo.get(Reconciliation.ReconcilePlan, plan_id)

    if plan do
      {:ok, _} = Reconciliation.update_plan(plan, %{status: :failed, error_message: message})
    end

    {:error, message}
  end

  # Pausing stops queues from starting new jobs but lets executing ones run to
  # completion; resuming in `after` covers apply failures. Mirrors
  # DatabaseMaintenanceWorker's quiet-window reservation.
  defp with_paused_queues(fun) do
    queues = QueueDiagnostics.queue_names()

    Enum.each(queues, &Oban.pause_queue(queue: &1))

    try do
      fun.()
    after
      Enum.each(queues, &Oban.resume_queue(queue: &1))
    end
  end

  defp wait_for_other_running_jobs(job_id) do
    if other_jobs_running?(job_id) do
      Logger.info("Reconcile is waiting for running jobs to finish before moving files")
      Process.sleep(Application.get_env(:pinchflat, :db_maintenance_poll_interval))
      wait_for_other_running_jobs(job_id)
    else
      :ok
    end
  end

  # The job ID is nil when run via `Oban.Testing.perform_job/2`
  defp other_jobs_running?(job_id) do
    from(j in Oban.Job, where: j.state == "executing")
    |> then(fn query -> if job_id, do: where(query, [j], j.id != ^job_id), else: query end)
    |> Repo.aggregate(:count)
    |> Kernel.>(0)
  end
end
