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
    <div class="max-w-full overflow-x-auto">
      <.table rows={@tasks} table_class="text-white">
        <:col :let={task} label="Task">
          {worker_to_task_name(task.job.worker)}
        </:col>
        <:col :let={task} label="Subject" class="max-w-sm">
          <.subtle_link href={task_to_link(task)}>
            <div class="whitespace-normal break-words">
              <div class="font-medium">{task_to_record_label(task)}</div>
              <div class="text-xs text-gray-400">{task_to_record_name(task)}</div>
            </div>
          </.subtle_link>
        </:col>
        <:col :let={task} label="Source" class="max-w-sm">
          <.subtle_link :if={task_source_link(task)} href={task_source_link(task)}>
            <div class="whitespace-normal break-words">
              <div class="font-medium">{task_source_label(task)}</div>
              <div class="text-xs text-gray-400">{task_source_name(task)}</div>
            </div>
          </.subtle_link>
          <span :if={!task_source_link(task)} class="text-gray-400">-</span>
        </:col>
        <:col :let={task} label="Attempt No.">
          {task.job.attempt}
        </:col>
        <:col :let={task} label="Progress">
          <.task_progress task={task} />
        </:col>
        <:col :let={task} label="Started At">
          {format_datetime(task.job.attempted_at)}
        </:col>
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
    """
  end

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("job:progress")

    source_id = Map.get(session, "source_id")
    source_id = if is_binary(source_id), do: String.to_integer(source_id), else: source_id

    {:ok, assign(socket, tasks: get_tasks(source_id), source_id: source_id)}
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, assign(socket, tasks: get_tasks(socket.assigns.source_id))}
  end

  def handle_info(%{topic: "job:progress", event: "update"}, socket) do
    {:noreply, assign(socket, tasks: get_tasks(socket.assigns.source_id))}
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
        from([t, j, mi, source] in base_query,
          where: source.id == ^source_id or mi.source_id == ^source_id
        )
      else
        base_query
      end

    base_query
    |> Repo.all()
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
          summary: format_progress_summary(assigns.task.progress_status, downloaded_bytes, total_bytes),
          eta: format_eta(assigns.task.progress_eta_seconds)
        )

      ~H"""
      <div class="min-w-52">
        <div class="mb-1 flex items-center justify-between text-xs text-gray-300">
          <span>{@label}</span>
          <span>{Float.round(@percent, 1)}%</span>
        </div>
        <div class="h-2 overflow-hidden rounded-full bg-slate-700">
          <div class="h-full rounded-full bg-blue-500 transition-all duration-300" style={"width: #{@width_percent}%"}></div>
        </div>
        <div class="mt-1 text-[11px] text-gray-400">
          <div>{@summary}</div>
          <div :if={@eta != nil}>ETA {@eta}</div>
        </div>
      </div>
      """
    else
      ~H"""
      <span class="text-gray-400">-</span>
      """
    end
  end

  defp task_action_label(task) do
    if String.ends_with?(task.job.worker, "MediaDownloadWorker"), do: "Stop", else: "Cancel"
  end

  defp format_progress_summary(status, nil, nil) do
    case status do
      "Queued" -> "Queued"
      "Prechecking media" -> "Checking the media before starting the download"
      "Waiting for transfer to start" -> "Waiting for yt-dlp to begin transferring data"
      "Downloading without known total" -> "Downloading, but the remote source has not provided a total size yet"
      nil -> "Queued"
      other -> other
    end
  end

  defp format_progress_summary(_status, downloaded_bytes, nil) do
    "#{readable_byte_size(downloaded_bytes)} downloaded"
  end

  defp format_progress_summary(_status, downloaded_bytes, total_bytes) do
    remaining_bytes = max(total_bytes - (downloaded_bytes || 0), 0)

    "#{readable_byte_size(downloaded_bytes)} of #{readable_byte_size(total_bytes)} done, #{readable_byte_size(remaining_bytes)} remaining"
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
end
