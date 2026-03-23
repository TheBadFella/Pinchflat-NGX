defmodule PinchflatWeb.Sources.MediaItemTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery
  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task

  @limit System.get_env("PAGINATION_LIMIT", "20") |> String.to_integer()

  def render(%{total_record_count: 0} = assigns) do
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
      <header class="flex justify-between items-center mb-4">
        <span class="flex items-center">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
          <span class="mx-2">
            Showing <.localized_number number={length(@records)} /> of <.localized_number number={@filtered_record_count} />
          </span>
        </span>

        <div class="bg-meta-4 rounded-md">
          <div class="relative">
            <span class="absolute left-2 top-1/2 -translate-y-1/2 flex">
              <.icon name="hero-magnifying-glass" />
            </span>

            <form phx-change="search_term" phx-submit="search_term">
              <input
                type="text"
                name="q"
                value={@search_term}
                placeholder="Search in table..."
                class="w-full bg-transparent pl-9 pr-4 border-0 focus:ring-0 focus:outline-none"
                phx-debounce="200"
              />
            </form>
          </div>
        </div>
      </header>
      <.table rows={@records} table_class="text-white">
        <:col :let={media_item} label="Title" class="max-w-xs">
          <section class="space-y-2">
            <div class="flex items-center space-x-1 gap-2">
              <.icon :if={media_item.last_error} name="hero-exclamation-circle-solid" class="shrink-0 text-red-500" />
              <.icon_button
                :if={@media_state != "downloaded"}
                icon_name="hero-arrow-down-tray"
                class="h-10 w-10"
                phx-click="force_download"
                phx-value-media-id={media_item.id}
                data-confirm="Are you sure you want to force a download of this media?"
                tooltip="Force Download"
              />
              <span class="truncate">
                <.subtle_link href={~p"/sources/#{@source.id}/media/#{media_item.id}"}>
                  {media_item.title}
                </.subtle_link>
              </span>
            </div>
            <div :if={media_item.last_error} class="whitespace-pre-wrap break-words text-xs text-red-300">
              {media_item.last_error}
            </div>
          </section>
        </:col>

        <:col :let={media_item} :if={@media_state == "other"} label="Prevent Download?">
          <.icon name={if media_item.prevent_download, do: "hero-check", else: "hero-x-mark"} />
        </:col>
        <:col :let={media_item} :if={@media_state == "other"} label="Excluded Reason">
          {excluded_reason(media_item, @source)}
        </:col>
        <:col :let={media_item} label="Upload Date">
          {DateTime.to_date(media_item.uploaded_at)}
        </:col>
        <:col :let={media_item} label="Size / Progress">
          {size_or_progress_label(media_item, Map.get(@tasks_by_media_item_id, media_item.id))}
        </:col>
        <:col :let={media_item} label="Action">
          <button
            :if={Map.has_key?(@tasks_by_media_item_id, media_item.id)}
            type="button"
            phx-click="stop_download"
            phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
            phx-value-media-id={media_item.id}
            data-confirm="Are you sure you want to stop this download?"
            class="rounded-md border border-red-400 px-3 py-1 text-xs font-medium text-red-300 transition hover:bg-red-500/10"
          >
            Stop
          </button>
          <span :if={!Map.has_key?(@tasks_by_media_item_id, media_item.id)} class="text-gray-400">-</span>
        </:col>
        <:col :let={media_item} label="" class="flex justify-end">
          <.icon_link href={~p"/sources/#{@source.id}/media/#{media_item.id}/edit"} icon="hero-pencil-square" class="mr-4" />
        </:col>
      </.table>
      <section class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("media_table")
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("job:progress")

    page = 1
    media_state = session["media_state"]

    source =
      session["source_id"]
      |> Sources.get_source!()
      |> Repo.preload(:media_profile)

    base_query = generate_base_query(source, media_state)
    pagination_attrs = fetch_pagination_attributes(base_query, page, nil)

    new_assigns =
      Map.merge(
        pagination_attrs,
        %{
          base_query: base_query,
          source: source,
          media_state: media_state
        }
      )

    {:ok, assign(socket, new_assigns)}
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    direction = if direction == "inc", do: 1, else: -1
    new_page = assigns.page + direction
    new_assigns = fetch_pagination_attributes(assigns.base_query, new_page, assigns.search_term)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("search_term", params, socket) do
    search_term = Map.get(params, "q", nil)
    new_assigns = fetch_pagination_attributes(socket.assigns.base_query, 1, search_term)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("force_download", %{"media-id" => media_id}, socket) do
    media_item = Media.get_media_item!(media_id)
    MediaDownloadWorker.kickoff_with_task(media_item, %{force: true})
    PinchflatWeb.Endpoint.broadcast("media_table", "reload", nil)

    {:noreply, socket}
  end

  def handle_event("stop_download", %{"task-id" => task_id}, socket) do
    task = Repo.get(Task, task_id)

    if task do
      {:ok, _task} = Tasks.delete_task(task)
      PinchflatWeb.Endpoint.broadcast("media_table", "reload", nil)
    end

    {:noreply, socket}
  end

  # This, along with the handle_info below, is a pattern to reload _all_
  # tables on page rather than just the one that triggered the reload.
  def handle_event("reload_page", _params, socket) do
    PinchflatWeb.Endpoint.broadcast("media_table", "reload", nil)

    {:noreply, socket}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, %{assigns: assigns} = socket) do
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_info(%{topic: "job:state", event: "change", payload: payload}, %{assigns: assigns} = socket)
      when is_map(payload) do
    if refresh_required?(assigns, payload) do
      new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term)
      {:noreply, assign(socket, new_assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: assigns} = socket) do
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term)

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

  defp fetch_pagination_attributes(base_query, page, ""), do: fetch_pagination_attributes(base_query, page, nil)

  defp fetch_pagination_attributes(base_query, page, nil) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    records =
      fetch_records(base_query, page)
      |> order_by(desc: :uploaded_at)
      |> Repo.all()

    build_pagination_attrs(%{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: nil,
      total_record_count: total_record_count,
      filtered_record_count: total_record_count
    })
  end

  defp fetch_pagination_attributes(base_query, page, search_term) do
    filtered_base_query = filtered_base_query(base_query, search_term)

    total_record_count = Repo.aggregate(base_query, :count, :id)
    filtered_record_count = Repo.aggregate(filtered_base_query, :count, :id)
    total_pages = max(ceil(filtered_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    records =
      fetch_records(filtered_base_query, page)
      |> order_by(desc: fragment("rank"), desc: :uploaded_at)
      |> Repo.all()

    build_pagination_attrs(%{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: search_term,
      total_record_count: total_record_count,
      filtered_record_count: filtered_record_count
    })
  end

  defp fetch_records(base_query, page) do
    offset = (page - 1) * @limit

    base_query
    |> limit(^@limit)
    |> offset(^offset)
  end

  defp generate_base_query(source, "pending") do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
  end

  defp generate_base_query(source, "downloaded") do
    MediaQuery.new()
    |> select(^select_fields())
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
  end

  defp generate_base_query(source, "other") do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(
      ^dynamic(
        ^MediaQuery.for_source(source) and
          (not (^MediaQuery.downloaded()) and not (^MediaQuery.pending()))
      )
    )
  end

  defp filtered_base_query(base_query, search_term) do
    base_query
    |> MediaQuery.require_assoc(:media_items_search_index)
    |> where(^MediaQuery.matches_search_term(search_term))
  end

  # Selecting only what we need GREATLY speeds up queries on large tables
  defp select_fields do
    [
      :id,
      :title,
      :uploaded_at,
      :prevent_download,
      :last_error,
      :duration_seconds,
      :livestream,
      :short_form_content,
      :media_size_bytes
    ]
  end

  defp excluded_reason(media_item, source) do
    cond do
      media_item.prevent_download ->
        "Prevented"

      before_cutoff?(media_item, source) ->
        "Before cutoff"

      too_short?(media_item, source) ->
        "Too short"

      too_long?(media_item, source) ->
        "Too long"

      source.media_profile.shorts_behaviour == :exclude and media_item.short_form_content ->
        "Shorts excluded"

      source.media_profile.shorts_behaviour == :only and not media_item.short_form_content ->
        "Only shorts"

      source.media_profile.livestream_behaviour == :exclude and media_item.livestream ->
        "Livestreams excluded"

      source.media_profile.livestream_behaviour == :only and not media_item.livestream ->
        "Only livestreams"

      is_binary(source.title_filter_regex) ->
        "Filtered by title"

      true ->
        "Filtered by source rules"
    end
  end

  defp before_cutoff?(media_item, %{download_cutoff_date: cutoff_date})
       when not is_nil(cutoff_date) and not is_nil(media_item.uploaded_at) do
    Date.compare(DateTime.to_date(media_item.uploaded_at), cutoff_date) == :lt
  end

  defp before_cutoff?(_media_item, _source), do: false

  defp too_short?(media_item, %{min_duration_seconds: min_duration})
       when not is_nil(min_duration) and not is_nil(media_item.duration_seconds) do
    media_item.duration_seconds < min_duration
  end

  defp too_short?(_media_item, _source), do: false

  defp too_long?(media_item, %{max_duration_seconds: max_duration})
       when not is_nil(max_duration) and not is_nil(media_item.duration_seconds) do
    media_item.duration_seconds > max_duration
  end

  defp too_long?(_media_item, _source), do: false

  defp build_pagination_attrs(attrs) do
    Map.put(attrs, :tasks_by_media_item_id, fetch_download_tasks(attrs.records))
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

    cond do
      total_bytes && downloaded_bytes ->
        remaining_bytes = max(total_bytes - downloaded_bytes, 0)

        "#{readable_byte_size(downloaded_bytes)} / #{readable_byte_size(total_bytes)} (#{readable_byte_size(remaining_bytes)} left)"

      total_bytes ->
        readable_byte_size(total_bytes)

      downloaded_bytes ->
        "#{readable_byte_size(downloaded_bytes)} downloaded"

      true ->
        waiting_size_label(task.progress_status)
    end
  end

  defp waiting_size_label("Queued"), do: "Queued"
  defp waiting_size_label("Prechecking media"), do: "Prechecking media"
  defp waiting_size_label("Waiting for transfer to start"), do: "Waiting for transfer to start"
  defp waiting_size_label("Downloading without known total"), do: "Downloading without known total"
  defp waiting_size_label(nil), do: "Queued"
  defp waiting_size_label(status), do: status

  defp readable_byte_size(bytes) do
    {num, suffix} = NumberUtils.human_byte_size(bytes, precision: 1)
    "#{num} #{suffix}"
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

  defp refresh_required?(assigns, payload) do
    payload[:source_id] == assigns.source.id ||
      Enum.any?(assigns.records, &(&1.id == payload[:media_item_id]))
  end

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
      :progress_updated_at
    ]
  end
end
