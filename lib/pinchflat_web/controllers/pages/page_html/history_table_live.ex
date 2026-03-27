defmodule Pinchflat.Pages.HistoryTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery
  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task
  alias PinchflatWeb.CustomComponents.TextComponents

  @limit System.get_env("PAGINATION_HISTORY_LIMIT", System.get_env("PAGINATION_LIMIT", "10")) |> String.to_integer()

  def render(%{records: []} = assigns) do
    ~H"""
    <div class="mb-4 flex items-center">
      <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" />
      <p class="ml-2">Nothing Here!</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <span class="mb-4 flex items-center">
        <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
        <span class="ml-2">
          Showing <.localized_number number={length(@records)} /> of <.localized_number number={@total_record_count} />
        </span>
      </span>
      <div class="space-y-4 md:hidden">
        <article :for={media_item <- @records} class="theme-surface-accent space-y-4 rounded-m3-lg p-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0 flex-1 space-y-2">
              <div class="flex items-start gap-2">
                <.icon :if={media_item.last_error} name="hero-exclamation-circle-solid" class="mt-0.5 shrink-0 text-red-500" />
                <div class="min-w-0">
                  <.subtle_link href={~p"/sources/#{media_item.source_id}/media/#{media_item.id}"}>
                    <span class="block whitespace-normal break-words font-medium text-theme-on-surface">{media_item.title}</span>
                  </.subtle_link>
                </div>
              </div>
              <.subtle_link href={~p"/sources/#{media_item.source_id}"}>
                <span class="text-sm text-theme-on-surface-muted">{media_item.source.custom_name}</span>
              </.subtle_link>
            </div>

            <div class="flex shrink-0 items-center gap-2">
              <.icon_button
                :if={is_nil(media_item.media_downloaded_at)}
                icon_name="hero-arrow-down-tray"
                class="h-10 w-10"
                phx-click="force_download"
                phx-value-media-id={media_item.id}
                data-confirm="Are you sure you want to force a download of this media?"
                tooltip="Force Download"
                tooltip_position="bottom-left"
              />
              <.icon_button
                :if={Map.has_key?(@tasks_by_media_item_id, media_item.id)}
                icon_name="hero-stop"
                class="h-10 w-10 border-red-400/80 bg-red-500/10 hover:border-red-300 hover:bg-red-500/20"
                icon_class="text-red-300"
                phx-click="stop_download"
                phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
                data-confirm="Are you sure you want to stop this download?"
                tooltip="Stop Download"
                tooltip_position="bottom-left"
              />
            </div>
          </div>

          <div :if={media_item.last_error} class="whitespace-pre-wrap break-words rounded-m3-sm bg-red-500/10 p-3 text-xs text-red-300">
            {media_item.last_error}
          </div>

          <dl class="grid grid-cols-1 gap-3 text-sm">
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Upload Date</dt>
              <dd class="text-right text-theme-on-surface">{DateTime.to_date(media_item.uploaded_at)}</dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Size / Progress</dt>
              <dd class="max-w-[65%] text-right text-theme-on-surface">
                <.progress_details media_item={media_item} task={Map.get(@tasks_by_media_item_id, media_item.id)} />
              </dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Indexed At</dt>
              <dd class="text-right text-theme-on-surface">{format_datetime(media_item.inserted_at)}</dd>
            </div>
            <div class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Downloaded At</dt>
              <dd class="text-right text-theme-on-surface">{format_datetime(media_item.media_downloaded_at)}</dd>
            </div>
          </dl>
        </article>
      </div>

      <div class="hidden md:block">
        <div class="max-w-full overflow-x-auto">
          <.table rows={@records}>
            <:col :let={media_item} label="Title" class="max-w-sm">
              <section class="space-y-2">
                <div class="flex items-start space-x-1 gap-2">
                  <.icon :if={media_item.last_error} name="hero-exclamation-circle-solid" class="shrink-0 text-red-500" />
                  <.icon_button
                    :if={is_nil(media_item.media_downloaded_at)}
                    icon_name="hero-arrow-down-tray"
                    class="h-10 w-10"
                    phx-click="force_download"
                    phx-value-media-id={media_item.id}
                    data-confirm="Are you sure you want to force a download of this media?"
                    tooltip="Force Download"
                    tooltip_position="bottom-left"
                  />
                  <.subtle_link href={~p"/sources/#{media_item.source_id}/media/#{media_item.id}"}>
                    <span class="block whitespace-normal break-words">{media_item.title}</span>
                  </.subtle_link>
                </div>

                <div :if={media_item.last_error} class="whitespace-pre-wrap break-words text-xs text-red-300">
                  {media_item.last_error}
                </div>
              </section>
            </:col>

            <:col :let={media_item} label="Upload Date">{DateTime.to_date(media_item.uploaded_at)}</:col>

            <:col :let={media_item} label="Size / Progress">
              <.progress_details media_item={media_item} task={Map.get(@tasks_by_media_item_id, media_item.id)} />
            </:col>

            <:col :let={media_item} label="Indexed At">{format_datetime(media_item.inserted_at)}</:col>

            <:col :let={media_item} label="Downloaded At">{format_datetime(media_item.media_downloaded_at)}</:col>

            <:col :let={media_item} label="Source" class="max-w-sm">
              <.subtle_link href={~p"/sources/#{media_item.source_id}"}>
                <span class="block whitespace-normal break-words">{media_item.source.custom_name}</span>
              </.subtle_link>
            </:col>

            <:col :let={media_item} label="Action">
              <.icon_button
                :if={Map.has_key?(@tasks_by_media_item_id, media_item.id)}
                icon_name="hero-stop"
                class="h-10 w-10 border-red-400/80 bg-red-500/10 hover:border-red-300 hover:bg-red-500/20"
                icon_class="text-red-300"
                phx-click="stop_download"
                phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
                data-confirm="Are you sure you want to stop this download?"
                tooltip="Stop Download"
                tooltip_position="bottom-left"
              />
              <span :if={!Map.has_key?(@tasks_by_media_item_id, media_item.id)} class="text-theme-on-surface-muted">-</span>
            </:col>
          </.table>
        </div>
      </div>

      <section class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("job:progress")

    page = 1
    base_query = generate_base_query(session["media_state"])
    pagination_attrs = fetch_pagination_attributes(base_query, page)

    {:ok, assign(socket, Map.merge(pagination_attrs, %{base_query: base_query}))}
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    direction = if direction == "inc", do: 1, else: -1
    new_page = assigns.page + direction
    new_assigns = fetch_pagination_attributes(assigns.base_query, new_page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("reload_page", _params, %{assigns: assigns} = socket) do
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("force_download", %{"media-id" => media_id}, %{assigns: assigns} = socket) do
    media_item = Media.get_media_item!(media_id)
    MediaDownloadWorker.kickoff_with_task(media_item, %{force: true, reset_last_error: true})

    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("stop_download", %{"task-id" => task_id}, %{assigns: assigns} = socket) do
    task = Repo.get(Task, task_id)

    if task do
      {:ok, _task} = Tasks.delete_task(task)
    end

    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_info(%{topic: "job:state", event: "change", payload: payload}, %{assigns: assigns} = socket)
      when is_map(payload) do
    if refresh_required?(payload) do
      new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)
      {:noreply, assign(socket, new_assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: assigns} = socket) do
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_info(%{topic: "job:progress", event: "update", payload: payload}, socket) when is_map(payload) do
    updated_tasks =
      update_task_progress(socket.assigns.tasks_by_media_item_id, socket.assigns.records, payload)

    {:noreply, assign(socket, :tasks_by_media_item_id, updated_tasks)}
  end

  def handle_info(%{topic: "job:progress", event: "update"}, socket) do
    {:noreply, socket}
  end

  defp fetch_pagination_attributes(base_query, page) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)
    records = fetch_records(base_query, page)

    %{
      page: page,
      total_pages: total_pages,
      records: records,
      total_record_count: total_record_count,
      tasks_by_media_item_id: fetch_download_tasks(records)
    }
  end

  defp fetch_records(base_query, page) do
    offset = (page - 1) * @limit

    base_query
    |> limit(^@limit)
    |> offset(^offset)
    |> Repo.all()
    |> Repo.preload(:source)
  end

  defp generate_base_query("pending") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.pending()))
    |> select(
      [m],
      struct(m, [
        :id,
        :title,
        :uploaded_at,
        :inserted_at,
        :media_downloaded_at,
        :source_id,
        :last_error,
        :media_size_bytes
      ])
    )
    |> order_by(desc: :id)
  end

  defp generate_base_query("downloaded") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.downloaded()))
    |> select(
      [m],
      struct(m, [
        :id,
        :title,
        :uploaded_at,
        :inserted_at,
        :media_downloaded_at,
        :source_id,
        :last_error,
        :media_size_bytes
      ])
    )
    |> order_by(desc: :id)
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end

  defp fetch_download_tasks(records) do
    media_item_ids = Enum.map(records, & &1.id)

    if media_item_ids == [] do
      %{}
    else
      from(t in Task,
        join: j in assoc(t, :job),
        where: t.media_item_id in ^media_item_ids,
        where: fragment("? LIKE ?", j.worker, ^"%.MediaDownloadWorker"),
        where: j.state in ^["available", "scheduled", "retryable", "executing"],
        preload: [job: j],
        order_by: [desc: t.inserted_at]
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn task, acc ->
        Map.put_new(acc, task.media_item_id, task)
      end)
    end
  end

  defp size_or_progress_label(media_item, nil) do
    case media_item.media_size_bytes do
      nil -> "Unknown"
      size -> readable_byte_size(size)
    end
  end

  defp size_or_progress_label(_media_item, task) do
    downloaded_bytes = task.progress_downloaded_bytes
    total_bytes = task.progress_total_bytes
    speed_bytes = task.progress_speed_bytes_per_second

    cond do
      total_bytes && downloaded_bytes ->
        remaining_bytes = max(total_bytes - downloaded_bytes, 0)

        "#{readable_byte_size(downloaded_bytes)} / #{readable_byte_size(total_bytes)} (#{readable_byte_size(remaining_bytes)} left)"
        |> maybe_append_speed(speed_bytes)

      total_bytes ->
        readable_byte_size(total_bytes)
        |> maybe_append_speed(speed_bytes)

      downloaded_bytes ->
        "#{readable_byte_size(downloaded_bytes)} downloaded"
        |> maybe_append_speed(speed_bytes)

      true ->
        (task.progress_status || "Queued")
        |> maybe_append_speed(speed_bytes)
    end
  end

  defp readable_byte_size(bytes) do
    {num, suffix} = NumberUtils.human_byte_size(bytes, precision: 1)
    "#{num} #{suffix}"
  end

  defp maybe_append_speed(text, nil), do: text
  defp maybe_append_speed(text, speed_bytes), do: "#{text} at #{readable_byte_size(speed_bytes)}/s"

  attr :media_item, :map, required: true
  attr :task, :any, default: nil

  defp progress_details(assigns) do
    ~H"""
    <div :if={is_nil(@task)} class="text-theme-on-surface">
      {size_or_progress_label(@media_item, nil)}
    </div>
    <div :if={!is_nil(@task)} class="min-w-40 space-y-2">
      <div class="text-right text-theme-on-surface">{size_or_progress_label(@media_item, @task)}</div>
      <div class="h-2 overflow-hidden rounded-full bg-theme-surface-4">
        <div
          class="h-full rounded-full bg-theme-primary transition-all duration-300"
          style={"width: #{progress_percent(@task)}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp progress_percent(task) do
    task.progress_percent
    |> Kernel.||(0.0)
    |> max(0.0)
    |> min(100.0)
    |> trunc()
  end

  defp update_task_progress(tasks_by_media_item_id, records, %{media_item_id: media_item_id} = payload)
       when is_integer(media_item_id) do
    if Enum.any?(records, &(&1.id == media_item_id)) do
      task = Map.get(tasks_by_media_item_id, media_item_id, %Task{id: payload[:task_id], job_id: payload.job_id})
      Map.put(tasks_by_media_item_id, media_item_id, struct(task, Map.take(payload, progress_fields())))
    else
      tasks_by_media_item_id
    end
  end

  defp update_task_progress(tasks_by_media_item_id, _records, _payload), do: tasks_by_media_item_id

  defp refresh_required?(payload) do
    payload[:media_item_id] ||
      indexing_worker?(payload[:worker]) ||
      media_download_worker?(payload[:worker])
  end

  defp media_download_worker?(worker), do: is_binary(worker) and String.ends_with?(worker, "MediaDownloadWorker")

  defp indexing_worker?(worker),
    do: worker in ["Pinchflat.FastIndexing.FastIndexingWorker", "Pinchflat.SlowIndexing.MediaCollectionIndexingWorker"]

  defp progress_fields do
    [
      :id,
      :job_id,
      :media_item_id,
      :progress_percent,
      :progress_status,
      :progress_downloaded_bytes,
      :progress_total_bytes,
      :progress_eta_seconds,
      :progress_speed_bytes_per_second,
      :progress_updated_at
    ]
  end
end
