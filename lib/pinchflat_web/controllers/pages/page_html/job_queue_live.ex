defmodule Pinchflat.Pages.JobQueueLive do
  @moduledoc """
  LiveView component for displaying the Oban job queue status.

  Shows jobs grouped by state with the ability to see details and cancel jobs.
  """
  use PinchflatWeb, :live_view
  use Pinchflat.Tasks.TasksQuery

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task
  alias PinchflatWeb.CustomComponents.TextComponents

  @refresh_interval_ms 5_000

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center space-x-2">
          <.icon_button icon_name="hero-arrow-path" class="h-8 w-8" phx-click="refresh" tooltip="Refresh" />
          <span class="text-sm text-theme-on-surface-muted">Auto-refreshes every {div(@refresh_interval, 1000)}s</span>
        </div>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
        <.stat_card label="Executing" count={@stats.executing} color="green" />
        <.stat_card label="Available" count={@stats.available} color="blue" />
        <.stat_card label="Scheduled" count={@stats.scheduled} color="yellow" />
        <.stat_card label="Retryable" count={@stats.retryable} color="orange" />
      </div>

      <div class="space-y-6">
        <.job_section
          :if={@executing_jobs != []}
          title="Executing Jobs"
          jobs={@executing_jobs}
          state="executing"
          show_cancel={true}
        />
        <.job_section
          :if={@available_jobs != []}
          title="Available Jobs (waiting to run)"
          jobs={@available_jobs}
          state="available"
          show_cancel={true}
        />
        <.job_section
          :if={@scheduled_jobs != []}
          title="Scheduled Jobs"
          jobs={@scheduled_jobs}
          state="scheduled"
          show_cancel={true}
        />
        <.job_section
          :if={@retryable_jobs != []}
          title="Retryable Jobs (will retry)"
          jobs={@retryable_jobs}
          state="retryable"
          show_cancel={true}
        />
        <.job_section
          :if={@failed_jobs != []}
          title="Recently Failed Jobs"
          jobs={@failed_jobs}
          state="discarded"
          show_cancel={false}
        />
        <div
          :if={
            @executing_jobs == [] && @available_jobs == [] && @scheduled_jobs == [] && @retryable_jobs == [] &&
              @failed_jobs == []
          }
          class="py-8 text-center text-theme-on-surface-muted"
        >
          <p>No active or pending jobs</p>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :color, :string, required: true

  defp stat_card(assigns) do
    color_classes =
      case assigns.color do
        "green" -> "theme-status-card-success"
        "blue" -> "theme-status-card-info"
        "yellow" -> "theme-status-card-warning"
        "orange" -> "theme-status-card-error"
        _ -> "theme-status-card-info"
      end

    assigns = assign(assigns, :color_classes, color_classes)

    ~H"""
    <div class={"theme-status-card #{@color_classes}"}>
      <div class="text-2xl font-bold">{@count}</div>

      <div class="text-sm text-theme-on-surface-muted">{@label}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :jobs, :list, required: true
  attr :state, :string, required: true
  attr :show_cancel, :boolean, default: false

  defp job_section(assigns) do
    ~H"""
    <div class="theme-surface-raised p-4">
      <h3 class="mb-3 text-lg font-semibold text-theme-on-surface">{@title}</h3>
      <div class="space-y-3 md:hidden">
        <article :for={row <- @jobs} class="theme-surface-accent space-y-3 rounded-m3-lg p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <div class="font-medium text-theme-on-surface">{worker_to_short_name(row.job.worker)}</div>
              <div class="mt-1 text-sm text-theme-on-surface-muted">{row_to_subject_label(row)}</div>
              <div class="break-words text-sm text-theme-on-surface">{row_to_subject_name(row)}</div>
            </div>
            <button
              :if={@show_cancel}
              phx-click="cancel_job"
              phx-value-job-id={row.job.id}
              class="theme-danger-text-button shrink-0 text-xs"
              data-confirm="Are you sure you want to cancel this job?"
            >
              Cancel
            </button>
          </div>

          <dl class="grid grid-cols-1 gap-2 text-sm">
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Source</dt>
              <dd class="max-w-[60%] text-right text-theme-on-surface">
                <div>{row_to_source_label(row)}</div>
                <div class="break-words text-xs text-theme-on-surface-muted">{row_to_source_name(row)}</div>
              </dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Attempt</dt>
              <dd class="text-right text-theme-on-surface">{row.job.attempt}/{row.job.max_attempts}</dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Scheduled</dt>
              <dd class="text-right text-theme-on-surface">{format_datetime(row.job.scheduled_at)}</dd>
            </div>
            <div :if={@state == "discarded"} class="flex items-center justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Error</dt>
              <dd class="flex items-center text-right">
                <button
                  type="button"
                  phx-click={show_modal(error_modal_id(row, :mobile))}
                  class="inline-flex items-center rounded-full border border-theme-outline bg-theme-surface px-4 py-2 text-xs font-medium text-theme-on-surface transition hover:border-theme-primary hover:bg-theme-surface-2 hover:text-theme-primary"
                >
                  Error Details
                </button>
              </dd>
            </div>
          </dl>

          <.error_modal :if={@state == "discarded"} row={row} modal_id={error_modal_id(row, :mobile)} />
        </article>
      </div>

      <div class="hidden md:block">
        <div class="max-w-full overflow-visible">
          <div class="overflow-x-auto overflow-y-hidden">
            <.table rows={@jobs} table_class="table-fixed text-sm">
              <:col :let={row} label="Worker">
                {worker_to_short_name(row.job.worker)}
              </:col>
              <:col :let={row} label="Subject" class="w-64 align-top">
                <div class="w-64 whitespace-normal break-words">
                  <div class="font-medium">{row_to_subject_label(row)}</div>
                  <div class="text-xs text-theme-on-surface-muted">{row_to_subject_name(row)}</div>
                </div>
              </:col>
              <:col :let={row} label="Source" class="w-64 align-top">
                <div class="w-64 whitespace-normal break-words">
                  <div class="font-medium">{row_to_source_label(row)}</div>
                  <div class="text-xs text-theme-on-surface-muted">{row_to_source_name(row)}</div>
                </div>
              </:col>
              <:col :let={row} label="Attempt">
                {row.job.attempt}/{row.job.max_attempts}
              </:col>
              <:col :let={row} label="Scheduled">
                {format_datetime(row.job.scheduled_at)}
              </:col>
              <:col :let={row} :if={@state == "discarded"} label="Error" class="w-40 align-middle">
                <button
                  type="button"
                  phx-click={show_modal(error_modal_id(row, :desktop))}
                  class="inline-flex items-center rounded-full border border-theme-outline bg-theme-surface px-4 py-2 text-xs font-medium text-theme-on-surface transition hover:border-theme-primary hover:bg-theme-surface-2 hover:text-theme-primary"
                >
                  Error Details
                </button>
                <.error_modal row={row} modal_id={error_modal_id(row, :desktop)} />
              </:col>
              <:col :let={row} :if={@show_cancel} label="">
                <button
                  phx-click="cancel_job"
                  phx-value-job-id={row.job.id}
                  class="theme-danger-text-button text-xs"
                  data-confirm="Are you sure you want to cancel this job?"
                >
                  Cancel
                </button>
              </:col>
            </.table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :modal_id, :string, required: true

  defp error_modal(assigns) do
    ~H"""
    <.modal id={@modal_id}>
      <div class="space-y-5 text-theme-on-surface">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-theme-primary">Job Error</p>
          <h4 class="mt-2 text-2xl font-semibold">{worker_to_short_name(@row.job.worker)}</h4>
          <p class="mt-2 text-sm text-theme-on-surface-muted">
            {@row.job.state |> String.capitalize()} for {row_to_subject_label(@row)}.
          </p>
        </div>

        <div class="grid gap-4 rounded-m3-lg border border-theme-outline/70 bg-theme-surface-3 p-4 text-sm sm:grid-cols-2">
          <div>
            <p class="text-xs uppercase tracking-wide text-theme-on-surface-muted">Subject</p>
            <p class="mt-1 font-medium">{row_to_subject_name(@row)}</p>
          </div>
          <div>
            <p class="text-xs uppercase tracking-wide text-theme-on-surface-muted">Source</p>
            <p class="mt-1 font-medium">{row_to_source_name(@row)}</p>
          </div>
        </div>

        <div>
          <p class="mb-2 text-xs uppercase tracking-wide text-theme-on-surface-muted">Details</p>
          <div class="max-h-[50vh] overflow-y-auto rounded-m3-lg border border-theme-outline/70 bg-theme-surface p-4">
            <pre class="theme-status-error whitespace-pre-wrap break-words font-sans text-sm leading-6">{format_errors(@row.job.errors, limit: :all)}</pre>
          </div>
        </div>

        <div class="flex justify-end">
          <button
            type="button"
            phx-click={hide_modal(@modal_id)}
            class="inline-flex items-center rounded-m3-sm bg-theme-primary px-5 py-3 text-sm font-medium text-theme-on-primary transition hover:bg-theme-primary/90"
          >
            Close
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def mount(_params, session, socket) do
    source_id = Map.get(session, "source_id")
    source_id = if is_binary(source_id), do: String.to_integer(source_id), else: source_id

    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("job:state")
      Process.send_after(self(), :tick, @refresh_interval_ms)
    end

    {:ok, assign(socket, refresh_interval: @refresh_interval_ms, source_id: source_id) |> fetch_job_data()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_job_data(socket)}
  end

  def handle_event("cancel_job", %{"job-id" => job_id}, socket) do
    job_id = String.to_integer(job_id)
    Oban.cancel_job(job_id)

    {:noreply, fetch_job_data(socket)}
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, fetch_job_data(socket)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_interval_ms)
    {:noreply, fetch_job_data(socket)}
  end

  defp fetch_job_data(socket) do
    stats = fetch_job_stats(socket.assigns.source_id)

    assign(socket,
      stats: stats,
      executing_jobs: fetch_jobs_by_state("executing", 10, socket.assigns.source_id),
      available_jobs: fetch_jobs_by_state("available", 10, socket.assigns.source_id),
      scheduled_jobs: fetch_jobs_by_state("scheduled", 10, socket.assigns.source_id),
      retryable_jobs: fetch_jobs_by_state("retryable", 10, socket.assigns.source_id),
      failed_jobs: fetch_failed_jobs(10, socket.assigns.source_id)
    )
  end

  defp fetch_job_stats(source_id) do
    query =
      base_job_scope(source_id)
      |> where([_t, j], j.state in ["executing", "available", "scheduled", "retryable"])
      |> group_by([_t, j], j.state)
      |> select([_t, j], {j.state, count(j.id)})

    stats_map = query |> Repo.all() |> Enum.into(%{})

    %{
      executing: Map.get(stats_map, "executing", 0),
      available: Map.get(stats_map, "available", 0),
      scheduled: Map.get(stats_map, "scheduled", 0),
      retryable: Map.get(stats_map, "retryable", 0)
    }
  end

  defp fetch_jobs_by_state(state, limit, source_id) do
    query =
      base_job_query(source_id)
      |> where([_t, j], j.state == ^state)

    query =
      case state do
        "executing" -> order_by(query, [_t, j], desc: j.attempted_at)
        "scheduled" -> order_by(query, [_t, j], asc: j.scheduled_at)
        _ -> order_by(query, [_t, j], asc: j.id)
      end

    query
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_failed_jobs(limit, source_id) do
    # Show recently failed jobs from the last 24 hours
    cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)

    base_job_query(source_id)
    |> where([_t, j], j.state in ["discarded", "cancelled"])
    |> where([_t, j], j.inserted_at > ^cutoff)
    |> order_by([_t, j], desc: j.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp base_job_scope(nil) do
    from(t in Task,
      join: j in assoc(t, :job),
      left_join: mi in assoc(t, :media_item),
      left_join: mi_source in assoc(mi, :source),
      left_join: source in assoc(t, :source)
    )
  end

  defp base_job_scope(source_id) do
    from([t, j, mi, mi_source, source] in base_job_scope(nil),
      where: source.id == ^source_id or mi_source.id == ^source_id
    )
  end

  defp base_job_query(source_id) do
    from([t, j, mi, mi_source, source] in base_job_scope(source_id),
      preload: [job: j, media_item: {mi, source: mi_source}, source: source]
    )
  end

  defp worker_to_short_name(worker) do
    worker
    |> String.split(".")
    |> Enum.at(-1)
    |> String.replace("Worker", "")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
  end

  defp row_to_subject_label(%{source: source}) when not is_nil(source), do: "Source ##{source.id}"
  defp row_to_subject_label(%{media_item: media_item}) when not is_nil(media_item), do: "Media ##{media_item.id}"
  defp row_to_subject_label(_row), do: "Unknown"

  defp row_to_subject_name(%{source: source}) when not is_nil(source), do: source.custom_name
  defp row_to_subject_name(%{media_item: media_item}) when not is_nil(media_item), do: media_item.title
  defp row_to_subject_name(_row), do: "Unknown"

  defp row_to_source(%{source: source}) when not is_nil(source), do: source
  defp row_to_source(%{media_item: %{source: source}}) when not is_nil(source), do: source
  defp row_to_source(_row), do: nil

  defp row_to_source_label(row) do
    case row_to_source(row) do
      nil -> "-"
      source -> "Source ##{source.id}"
    end
  end

  defp row_to_source_name(row) do
    case row_to_source(row) do
      nil -> "-"
      source -> source.custom_name
    end
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M:%S"})
  end

  defp format_errors([], _opts), do: "No errors"

  defp format_errors(errors, opts) when is_list(errors) do
    limit = Keyword.get(opts, :limit, 3)

    errors
    |> maybe_take_errors(limit)
    |> Enum.map_join("\n\n", fn error ->
      case error do
        %{"error" => msg, "at" => at} -> "#{at}: #{msg}"
        %{"error" => msg} -> msg
        msg when is_binary(msg) -> msg
        other -> inspect(other)
      end
    end)
  end

  defp maybe_take_errors(errors, :all), do: errors
  defp maybe_take_errors(errors, limit), do: Enum.take(errors, limit)

  defp error_modal_id(row, context), do: "job-error-#{row.job.id}-#{context}"
end
