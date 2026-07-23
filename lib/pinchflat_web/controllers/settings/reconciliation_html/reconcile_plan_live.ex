defmodule Pinchflat.Settings.ReconcilePlanLive do
  use PinchflatWeb, :live_view

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Reconciliation
  alias Pinchflat.Utils.NumberUtils

  @limit 20
  @filters ~w(all move backfill delete redownload skip collision)

  def render(%{plan: nil} = assigns) do
    ~H"""
    <div class="rounded-sm border border-stroke bg-white px-5 py-5 shadow-default dark:border-strokedark dark:bg-boxdark sm:px-7.5 mb-6">
      <h3 class="text-lg font-semibold text-white mb-2">Latest Run</h3>
      <p class="text-bodydark text-sm">
        No reconcile runs yet — scan and build a plan above to see what would change.
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="rounded-sm border border-stroke bg-white px-5 py-5 shadow-default dark:border-strokedark dark:bg-boxdark sm:px-7.5 mb-6">
      <div class="flex justify-between items-center mb-2 flex-wrap gap-3">
        <h3 class="text-lg font-semibold text-white">
          Latest Run — {scope_name(@plan)} <span class="text-bodydark text-sm">({humanize_mode(@plan.mode)})</span>
        </h3>
        <div class="flex items-center gap-3">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload" tooltip="Refresh" />
          <.link
            :if={@plan.status == :ready && applyable_count(@plan) > 0}
            href={~p"/reconciliation/apply/#{@plan.id}"}
            method="post"
            data-confirm={apply_confirmation(@plan)}
          >
            <.button color="bg-primary" rounding="rounded-lg">
              <.icon name="hero-play" class="h-4 w-4 mr-1" /> Apply This Plan
            </.button>
          </.link>
        </div>
      </div>

      <p class="text-sm mb-4">
        <span class="text-bodydark">Status:</span>
        <span class={status_class(@plan.status)}>{status_line(@plan)}</span>
      </p>

      <div class="grid grid-cols-2 md:grid-cols-6 gap-4 mb-4">
        <div class="bg-meta-4 rounded-lg p-4">
          <p class="text-sm text-bodydark">Moves</p>
          <p class="text-2xl font-bold text-white">{@plan.move_count}</p>
        </div>
        <div class="bg-meta-4 rounded-lg p-4">
          <p class="text-sm text-bodydark">Backfills</p>
          <p class="text-2xl font-bold text-white">{@plan.backfill_count}</p>
        </div>
        <div class="bg-meta-4 rounded-lg p-4">
          <p class="text-sm text-bodydark">Deletions</p>
          <p class={"text-2xl font-bold #{if @plan.delete_count > 0, do: "text-red-400", else: "text-white"}"}>
            {@plan.delete_count}
          </p>
          <p :if={@plan.delete_count > 0} class="text-xs text-red-400 mt-1">Files will be permanently deleted</p>
        </div>
        <div class="bg-meta-4 rounded-lg p-4">
          <p class="text-sm text-bodydark">Re-downloads</p>
          <p class={"text-2xl font-bold #{if @plan.redownload_count > 0, do: "text-yellow-500", else: "text-white"}"}>
            {@plan.redownload_count}
          </p>
          <p :if={@plan.redownload_count > 0} class="text-xs text-yellow-500 mt-1">Uses bandwidth</p>
        </div>
        <div class="bg-meta-4 rounded-lg p-4">
          <p class="text-sm text-bodydark">Skipped</p>
          <p class="text-2xl font-bold text-white">{@plan.skip_count}</p>
        </div>
        <div class="bg-meta-4 rounded-lg p-4">
          <p class="text-sm text-bodydark">Collisions</p>
          <p class={"text-2xl font-bold #{if @plan.collision_count > 0, do: "text-yellow-500", else: "text-white"}"}>
            {@plan.collision_count}
          </p>
        </div>
      </div>

      <div class="flex gap-2 mb-4 flex-wrap">
        <button
          :for={filter <- filters()}
          phx-click="filter"
          phx-value-filter={filter}
          class={[
            "px-3 py-1 rounded-full text-sm border",
            if(@filter == filter,
              do: "bg-primary text-white border-primary",
              else: "text-bodydark border-strokedark hover:border-primary"
            )
          ]}
        >
          {filter_label(filter)}
        </button>
      </div>

      <p :if={@records == []} class="text-bodydark text-sm">Nothing here for this filter.</p>

      <div :if={@records != []} class="max-w-full overflow-x-auto">
        <.table rows={@records} table_class="text-white text-sm">
          <:col :let={item} label="Action">
            <span class={action_class(item.action)}>{item.action}</span>
          </:col>
          <:col :let={item} label="File">{item.attribute}</:col>
          <:col :let={item} label="From" class="max-w-lg">
            <span class="break-all text-xs">{item.from_path}</span>
          </:col>
          <:col :let={item} label="To" class="max-w-lg">
            <span class="break-all text-xs">{item.to_path}</span>
          </:col>
          <:col :let={item} label="Status">{item.status}</:col>
          <:col :let={item} label="Detail" class="max-w-xs">
            <span class="text-xs text-bodydark">{item.detail}</span>
          </:col>
        </.table>
      </div>

      <section :if={@total_pages > 1} class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: PinchflatWeb.Endpoint.subscribe("job:state")

    {:ok, load_assigns(socket, "all", 1)}
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: assigns} = socket) do
    {:noreply, load_assigns(socket, assigns.filter, assigns.page)}
  end

  def handle_event("reload", _params, %{assigns: assigns} = socket) do
    {:noreply, load_assigns(socket, assigns.filter, assigns.page)}
  end

  def handle_event("filter", %{"filter" => filter}, socket) when filter in @filters do
    {:noreply, load_assigns(socket, filter, 1)}
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    delta = if direction == "inc", do: 1, else: -1

    {:noreply, load_assigns(socket, assigns.filter, assigns.page + delta)}
  end

  defp load_assigns(socket, filter, page) do
    case Reconciliation.latest_plan() do
      nil ->
        assign(socket, plan: nil, filter: "all", page: 1, records: [], total_pages: 1)

      plan ->
        plan = Repo.preload(plan, :source)
        query = Reconciliation.plan_items_query(plan, filter_to_action(filter))
        total_record_count = Repo.aggregate(query, :count, :id)
        total_pages = max(ceil(total_record_count / @limit), 1)
        page = NumberUtils.clamp(page, 1, total_pages)
        records = query |> limit(^@limit) |> offset(^((page - 1) * @limit)) |> Repo.all()

        assign(socket, plan: plan, filter: filter, page: page, records: records, total_pages: total_pages)
    end
  end

  defp filters, do: @filters

  defp filter_to_action("all"), do: nil
  defp filter_to_action("move"), do: :move
  defp filter_to_action("backfill"), do: :backfill
  defp filter_to_action("delete"), do: :delete
  defp filter_to_action("redownload"), do: :redownload
  defp filter_to_action("skip"), do: :skip
  defp filter_to_action("collision"), do: :collision

  defp filter_label("all"), do: "All"
  defp filter_label("move"), do: "Moves"
  defp filter_label("backfill"), do: "Backfills"
  defp filter_label("delete"), do: "Deletions"
  defp filter_label("redownload"), do: "Re-downloads"
  defp filter_label("skip"), do: "Skipped"
  defp filter_label("collision"), do: "Collisions"

  defp scope_name(%{source: %{custom_name: name}}) when is_binary(name), do: name
  defp scope_name(_plan), do: "All sources"

  defp humanize_mode(:local), do: "Local only"
  defp humanize_mode(:online), do: "Online mode"
  defp humanize_mode(:full), do: "Full sync"
  defp humanize_mode(other), do: to_string(other)

  defp applyable_count(plan) do
    plan.move_count + plan.backfill_count + plan.delete_count + plan.redownload_count
  end

  defp apply_confirmation(plan) do
    base =
      "Apply this plan? #{plan.move_count} file move(s) and #{plan.backfill_count} backfill(s) will run. " <>
        "Job queues are paused while running jobs finish, then files are moved and the queues resume on their own."

    base
    |> maybe_append_delete_warning(plan)
    |> maybe_append_redownload_warning(plan)
  end

  defp maybe_append_delete_warning(text, %{delete_count: count}) when count > 0 do
    text <>
      " WARNING: #{count} sidecar file(s) whose setting is turned off will be PERMANENTLY DELETED. " <>
      "Review the Deletions filter before applying. This cannot be undone."
  end

  defp maybe_append_delete_warning(text, _plan), do: text

  defp maybe_append_redownload_warning(text, %{redownload_count: count}) when count > 0 do
    text <>
      " #{count} item(s) will be fully re-downloaded (this uses bandwidth). Review the Re-downloads filter first."
  end

  defp maybe_append_redownload_warning(text, _plan), do: text

  defp status_line(%{status: :building}), do: "Scan in progress — this report fills in as it builds"
  defp status_line(%{status: :ready}), do: "Ready to review — nothing has been changed yet"
  defp status_line(%{status: :applying}), do: "Applying — waiting for running jobs, then moving files"

  defp status_line(%{status: :applied} = plan) do
    error_suffix = if plan.error_count > 0, do: " (#{plan.error_count} row(s) failed — see details below)", else: ""

    "Applied#{error_suffix}"
  end

  defp status_line(%{status: :failed} = plan), do: "Failed: #{plan.error_message}"
  defp status_line(%{status: :stale}), do: "Stale — superseded by a newer run or a settings change"

  defp status_class(:ready), do: "text-blue-400"
  defp status_class(:applied), do: "text-green-400"
  defp status_class(:failed), do: "text-red-400"
  defp status_class(_status), do: "text-bodydark"

  defp action_class(:move), do: "text-blue-400"
  defp action_class(:backfill), do: "text-green-400"
  defp action_class(:delete), do: "text-red-400"
  defp action_class(:redownload), do: "text-yellow-500"
  defp action_class(:collision), do: "text-yellow-500"
  defp action_class(_action), do: "text-bodydark"
end
