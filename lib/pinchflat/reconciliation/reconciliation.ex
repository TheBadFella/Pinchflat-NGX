defmodule Pinchflat.Reconciliation do
  @moduledoc """
  The Reconciliation context: persisting and querying reconcile plans (dry-run
  reports of file moves/backfills/deletions) and their items. The heavy lifting
  lives in `PlanBuilder` (dry run) and `PlanApplier` (execution).
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Reconciliation.ReconcilePlan
  alias Pinchflat.Reconciliation.ReconcilePlanItem

  # Old plans are pruned down to this many whenever a new plan is created
  @plans_to_keep 10

  @doc """
  Creates a reconcile plan, pruning old plans beyond the retention limit.

  Returns {:ok, %ReconcilePlan{}} | {:error, %Ecto.Changeset{}}
  """
  def create_plan(attrs) do
    result =
      %ReconcilePlan{}
      |> ReconcilePlan.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, _plan} ->
        prune_old_plans()
        result

      err ->
        err
    end
  end

  @doc """
  Updates a reconcile plan.

  Returns {:ok, %ReconcilePlan{}} | {:error, %Ecto.Changeset{}}
  """
  def update_plan(%ReconcilePlan{} = plan, attrs) do
    plan
    |> ReconcilePlan.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets a single reconcile plan.

  Returns %ReconcilePlan{}. Raises `Ecto.NoResultsError` if it does not exist.
  """
  def get_plan!(id), do: Repo.get!(ReconcilePlan, id)

  @doc """
  Returns the most recently created plan (any status), or nil.
  """
  def latest_plan do
    ReconcilePlan
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns recent plans, newest first.
  """
  def list_plans(limit \\ @plans_to_keep) do
    ReconcilePlan
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Bulk-inserts plan items. Attrs maps must contain action/attribute/reconcile_plan_id;
  timestamps are filled in here since `insert_all` doesn't.

  Returns the number of inserted rows.
  """
  def create_plan_items(attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now(:second)

    attrs_list
    |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))
    |> Enum.chunk_every(200)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} = Repo.insert_all(ReconcilePlanItem, chunk)
      acc + count
    end)
  end

  @doc """
  Updates a single plan item.

  Returns {:ok, %ReconcilePlanItem{}} | {:error, %Ecto.Changeset{}}
  """
  def update_plan_item(%ReconcilePlanItem{} = item, attrs) do
    item
    |> ReconcilePlanItem.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  A composable query for a plan's items, optionally filtered to one action,
  ordered stably for pagination.
  """
  def plan_items_query(%ReconcilePlan{} = plan, action \\ nil) do
    ReconcilePlanItem
    |> where(reconcile_plan_id: ^plan.id)
    |> then(fn query ->
      if action, do: where(query, action: ^action), else: query
    end)
    |> order_by(asc: :id)
  end

  @doc """
  Returns the plan's items grouped as %{action => count}.
  """
  def count_plan_items_by_action(%ReconcilePlan{} = plan) do
    ReconcilePlanItem
    |> where(reconcile_plan_id: ^plan.id)
    |> group_by(:action)
    |> select([rpi], {rpi.action, count(rpi.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Recomputes and stores the plan's per-action counts from its items.

  Returns {:ok, %ReconcilePlan{}}
  """
  def refresh_plan_counts(%ReconcilePlan{} = plan) do
    counts = count_plan_items_by_action(plan)

    update_plan(plan, %{
      move_count: Map.get(counts, :move, 0),
      backfill_count: Map.get(counts, :backfill, 0),
      delete_count: Map.get(counts, :delete, 0),
      redownload_count: Map.get(counts, :redownload, 0),
      skip_count: Map.get(counts, :skip, 0),
      collision_count: Map.get(counts, :collision, 0)
    })
  end

  @doc """
  Marks any still-reviewable (ready) plans as stale. Used when a new plan
  supersedes them or path-affecting records change.

  Returns the number of plans marked.
  """
  def mark_ready_plans_stale do
    {count, _} =
      ReconcilePlan
      |> where(status: :ready)
      |> Repo.update_all(set: [status: "stale"])

    count
  end

  defp prune_old_plans do
    keeper_ids =
      ReconcilePlan
      |> order_by(desc: :id)
      |> limit(@plans_to_keep)
      |> select([rp], rp.id)
      |> Repo.all()

    ReconcilePlan
    |> where([rp], rp.id not in ^keeper_ids)
    |> Repo.delete_all()
  end
end
