defmodule Pinchflat.Pages.JobTableLive do
  use PinchflatWeb, :live_view
  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Utils.NumberUtils
  alias PinchflatWeb.CustomComponents.TextComponents

  def render(%{tasks: []} = assigns) do
    ~H"""
    <div class="mb-4 flex items-center">
      <p>Nothing Here!</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="space-y-4 md:hidden">
        <article :for={task <- @tasks} class="theme-surface-accent space-y-4 rounded-m3-lg p-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="font-medium text-theme-on-surface">{worker_to_task_name(task.job.worker)}</div>
              <.subtle_link href={task_to_link(task)}>
                <div class="mt-1 text-sm text-theme-on-surface-muted">{task_to_record_label(task)}</div>
                <div class="break-words text-sm text-theme-on-surface">{task_to_record_name(task)}</div>
              </.subtle_link>
            </div>
            <button
              type="button"
              phx-click="cancel_task"
              phx-value-task-id={task.id}
              data-confirm={"Are you sure you want to #{task_action_label(task)} this task?"}
              class="shrink-0 rounded-md border border-red-400 px-3 py-1 text-xs font-medium text-red-300 transition hover:bg-red-500/10"
            >
              {task_action_label(task)}
            </button>
          </div>

          <dl class="grid grid-cols-1 gap-3 text-sm">
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Source</dt>
              <dd class="max-w-[60%] text-right">
                <.subtle_link :if={task_source_link(task)} href={task_source_link(task)}>
                  <div class="text-theme-on-surface">{task_source_label(task)}</div>
                  <div class="break-words text-xs text-theme-on-surface-muted">{task_source_name(task)}</div>
                </.subtle_link>
                <span :if={!task_source_link(task)} class="text-theme-on-surface-muted">-</span>
              </dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Attempt No.</dt>
              <dd class="text-right text-theme-on-surface">{task.job.attempt}</dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Started At</dt>
              <dd class="text-right text-theme-on-surface">{format_datetime(task.job.attempted_at)}</dd>
            </div>
            <div class="space-y-2">
              <dt class="text-theme-on-surface-muted">Progress</dt>
              <dd><.task_progress task={task} /></dd>
            </div>
          </dl>
        </article>
      </div>

      <div class="hidden md:block max-w-full overflow-x-auto">
        <.table rows={@tasks}>
          <:col :let={task} label="Task">{worker_to_task_name(task.job.worker)}</:col>

          <:col :let={task} label="Subject" class="max-w-sm">
            <.subtle_link href={task_to_link(task)}>
              <div class="whitespace-normal break-words">
                <div class="font-medium">{task_to_record_label(task)}</div>
                <div class="text-xs text-theme-on-surface-muted">{task_to_record_name(task)}</div>
              </div>
            </.subtle_link>
          </:col>
          <:col :let={task} label="Source" class="max-w-sm">
            <.subtle_link :if={task_source_link(task)} href={task_source_link(task)}>
              <div class="whitespace-normal break-words">
                <div class="font-medium">{task_source_label(task)}</div>
                <div class="text-xs text-theme-on-surface-muted">{task_source_name(task)}</div>
              </div>
            </.subtle_link>
            <span :if={!task_source_link(task)} class="text-theme-on-surface-muted">-</span>
          </:col>
          <:col :let={task} label="Attempt No.">{task.job.attempt}</:col>

          <:col :let={task} label="Progress"><.task_progress task={task} /></:col>

          <:col :let={task} label="Started At">{format_datetime(task.job.attempted_at)}</:col>

          <:col :let={task} label="">
            <button
              type="button"
              phx-click="cancel_task"
              phx-value-task-id={task.id}
              data-confirm={"Are you sure you want to #{task_action_label(task)} this task?"}
              class="rounded-md border border-red-400 px-3 py-1 text-xs font-medium text-red-300 transition hover:bg-red-500/10"
            >
              {task_action_label(task)}
            </button>
          </:col>
        </.table>
      </div>
    </div>
    """
  end

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("job:progress")

    source_id = Map.get(session, "source_id")
    source_id = if is_binary(source_id), do: String.to_integer(source_id), else: source_id

    {:ok, assign(socket, tasks: get_tasks(source_id), source_id: source_id)}
  end

  def handle_info(%{topic: "job:state", event: "change", payload: %{job_id: job_id} = payload}, socket) do
    {:noreply, apply_task_state_change(socket, job_id, payload)}
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, assign(socket, tasks: get_tasks(socket.assigns.source_id))}
  end

  def handle_info(%{topic: "job:progress", event: "update", payload: %{job_id: job_id} = payload}, socket) do
    {:noreply, assign(socket, tasks: update_task_progress(socket.assigns.tasks, job_id, payload))}
  end

  def handle_info(%{topic: "job:progress", event: "update"}, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_task", %{"task-id" => task_id}, socket) do
    task = Repo.get(Task, task_id)

    if task do
      {:ok, _task} = Tasks.delete_task(task)
    end

    {:noreply, assign(socket, tasks: get_tasks(socket.assigns.source_id))}
  end

  defp get_tasks(source_id) do
    base_query =
      from(t in Task,
        join: j in assoc(t, :job),
        left_join: mi in assoc(t, :media_item),
        left_join: mi_source in assoc(mi, :source),
        left_join: source in assoc(t, :source),
        where: j.state == "executing",
        where: ^"show_in_dashboard" in j.tags,
        preload: [job: j, media_item: {mi, source: mi_source}, source: source],
        order_by: [desc: j.attempted_at]
      )

    base_query =
      if source_id do
        from([_t, _j, mi, _mi_source, source] in base_query,
          where: source.id == ^source_id or mi.source_id == ^source_id
        )
      else
        base_query
      end

    base_query
    |> Repo.all()
  end

  defp get_task(job_id) do
    from(t in Task,
      join: j in assoc(t, :job),
      left_join: mi in assoc(t, :media_item),
      left_join: mi_source in assoc(mi, :source),
      left_join: source in assoc(t, :source),
      where: t.job_id == ^job_id,
      where: j.state == "executing",
      where: ^"show_in_dashboard" in j.tags,
      preload: [job: j, media_item: {mi, source: mi_source}, source: source]
    )
    |> Repo.one()
  end

  defp apply_task_state_change(socket, job_id, payload) do
    if track_job?(socket.assigns, job_id, payload) do
      case get_task(job_id) do
        nil -> assign(socket, tasks: remove_task(socket.assigns.tasks, job_id))
        task -> assign(socket, tasks: upsert_task(socket.assigns.tasks, task))
      end
    else
      socket
    end
  end

  defp track_job?(assigns, job_id, payload) do
    Enum.any?(assigns.tasks, &(&1.job_id == job_id)) ||
      (payload[:show_in_dashboard] && source_matches?(assigns.source_id, payload[:source_id]))
  end

  defp source_matches?(nil, _source_id), do: true
  defp source_matches?(_source_id, nil), do: false
  defp source_matches?(source_id, payload_source_id), do: source_id == payload_source_id

  defp update_task_progress(tasks, job_id, payload) do
    Enum.map(tasks, fn
      %{job_id: ^job_id} = task -> merge_task_progress(task, payload)
      task -> task
    end)
  end

  defp merge_task_progress(task, payload) do
    struct(task, Map.take(payload, progress_fields()))
  end

  defp upsert_task(tasks, new_task) do
    if Enum.any?(tasks, &(&1.job_id == new_task.job_id)) do
      Enum.map(tasks, fn
        %{job_id: job_id} when job_id == new_task.job_id -> new_task
        task -> task
      end)
    else
      [new_task | tasks]
    end
  end

  defp remove_task(tasks, job_id) do
    Enum.reject(tasks, &(&1.job_id == job_id))
  end

  defp progress_fields do
    [
      :progress_percent,
      :progress_status,
      :progress_downloaded_bytes,
      :progress_total_bytes,
      :progress_eta_seconds,
      :progress_speed_bytes_per_second,
      :progress_updated_at
    ]
  end

  defp worker_to_task_name(worker) do
    final_module_part =
      worker
      |> String.split(".")
      |> Enum.at(-1)

    map_worker_to_task_name(final_module_part)
  end

  defp map_worker_to_task_name("FastIndexingWorker"), do: "Fast Indexing Source"
  defp map_worker_to_task_name("MediaDownloadWorker"), do: "Downloading Media"
  defp map_worker_to_task_name("MediaCollectionIndexingWorker"), do: "Indexing Source"
  defp map_worker_to_task_name("MediaQualityUpgradeWorker"), do: "Upgrading Media Quality"
  defp map_worker_to_task_name("SourceMetadataStorageWorker"), do: "Fetching Source Metadata"
  defp map_worker_to_task_name(other), do: other <> " (Report to Devs)"

  defp task_to_record_name(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> source.custom_name
      %Task{media_item: mi} when mi != nil -> mi.title
      _ -> "Unknown Record"
    end
  end

  defp task_to_record_label(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> "Source ##{source.id}"
      %Task{media_item: mi} when mi != nil -> "Media ##{mi.id}"
      _ -> "Unknown Record"
    end
  end

  defp task_to_link(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> ~p"/sources/#{source.id}"
      %Task{media_item: mi} when mi != nil -> ~p"/sources/#{mi.source_id}/media/#{mi}"
      _ -> "#"
    end
  end

  defp task_source(%Task{source: source}) when source != nil, do: source
  defp task_source(%Task{media_item: %{source: source}}) when source != nil, do: source
  defp task_source(_task), do: nil

  defp task_source_label(task) do
    case task_source(task) do
      nil -> "-"
      source -> "Source ##{source.id}"
    end
  end

  defp task_source_name(task) do
    case task_source(task) do
      nil -> nil
      source -> source.custom_name
    end
  end

  defp task_source_link(task) do
    case task_source(task) do
      nil -> nil
      source -> ~p"/sources/#{source.id}"
    end
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end

  attr :task, :map, required: true

  defp task_progress(assigns) do
    if String.ends_with?(assigns.task.job.worker, "MediaDownloadWorker") do
      percent = assigns.task.progress_percent || 0.0
      downloaded_bytes = assigns.task.progress_downloaded_bytes
      total_bytes = assigns.task.progress_total_bytes
      speed_bytes = assigns.task.progress_speed_bytes_per_second

      label =
        cond do
          is_binary(assigns.task.progress_status) -> assigns.task.progress_status
          percent > 0 -> "Downloading"
          true -> "Preparing"
        end

      assigns =
        assign(assigns,
          percent: percent,
          width_percent: trunc(percent),
          label: label,
          summary: format_progress_summary(assigns.task.progress_status, downloaded_bytes, total_bytes, speed_bytes),
          eta: format_eta(assigns.task.progress_eta_seconds)
        )

      ~H"""
      <div class="min-w-52">
        <div class="mb-1 flex items-center justify-between text-xs text-theme-on-surface-muted">
          <span>{@label}</span>
          <span>{Float.round(@percent, 1)}%</span>
        </div>
        <div class="h-2 overflow-hidden rounded-full bg-theme-surface-4">
          <div class="h-full rounded-full bg-theme-primary transition-all duration-300" style={"width: #{@width_percent}%"}>
          </div>
        </div>
        <div class="mt-1 text-[11px] text-theme-on-surface-muted">
          <div>{@summary}</div>
          <div :if={@eta != nil}>ETA {@eta}</div>
        </div>
      </div>
      """
    else
      ~H"""
      <span class="text-theme-on-surface-muted">-</span>
      """
    end
  end

  defp task_action_label(task) do
    if String.ends_with?(task.job.worker, "MediaDownloadWorker"), do: "Stop", else: "Cancel"
  end

  defp format_progress_summary(status, nil, nil, nil) do
    case status do
      "Queued" -> "Queued"
      "Prechecking media" -> "Checking the media before starting the download"
      "Waiting for transfer to start" -> "Waiting for yt-dlp to begin transferring data"
      "Downloading without known total" -> "Downloading, but the remote source has not provided a total size yet"
      nil -> "Queued"
      other -> other
    end
  end

  defp format_progress_summary(status, nil, nil, speed_bytes) do
    maybe_append_speed(status || "Queued", speed_bytes)
  end

  defp format_progress_summary(_status, downloaded_bytes, nil, speed_bytes) do
    "#{readable_byte_size(downloaded_bytes)} downloaded"
    |> maybe_append_speed(speed_bytes)
  end

  defp format_progress_summary(_status, downloaded_bytes, total_bytes, speed_bytes) do
    remaining_bytes = max(total_bytes - (downloaded_bytes || 0), 0)

    "#{readable_byte_size(downloaded_bytes)} of #{readable_byte_size(total_bytes)} done, #{readable_byte_size(remaining_bytes)} remaining"
    |> maybe_append_speed(speed_bytes)
  end

  defp format_eta(nil), do: nil
  defp format_eta(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_eta(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    if minutes < 60 do
      "#{minutes}m #{remaining_seconds}s"
    else
      hours = div(minutes, 60)
      remaining_minutes = rem(minutes, 60)
      "#{hours}h #{remaining_minutes}m"
    end
  end

  defp readable_byte_size(nil), do: "0 B"

  defp readable_byte_size(bytes) do
    {num, suffix} = NumberUtils.human_byte_size(bytes, precision: 1)
    "#{num} #{suffix}"
  end

  defp maybe_append_speed(text, nil), do: text
  defp maybe_append_speed(text, speed_bytes), do: "#{text} at #{readable_byte_size(speed_bytes)}/s"
end
