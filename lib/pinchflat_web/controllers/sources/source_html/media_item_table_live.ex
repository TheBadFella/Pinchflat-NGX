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
      <header class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <span class="flex items-center">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
          <span class="mx-2">
            Showing <.localized_number number={length(@records)} /> of <.localized_number number={@filtered_record_count} />
          </span>
        </span>

        <div class="theme-surface-accent rounded-m3-sm">
          <div class="relative">
            <span class="absolute left-3 top-1/2 flex -translate-y-1/2 text-theme-on-surface-muted">
              <.icon name="hero-magnifying-glass" />
            </span>
            <form phx-change="search_term" phx-submit="search_term">
              <input
                type="text"
                name="q"
                value={@search_term}
                placeholder="Search in table..."
                class="w-full border-0 bg-transparent py-3 pl-10 pr-4 text-theme-on-surface placeholder:text-theme-on-surface-muted focus:ring-0 focus:outline-none"
                phx-debounce="200"
              />
            </form>
          </div>
        </div>
      </header>
      <div class="space-y-4 md:hidden">
        <article :for={media_item <- @records} class="theme-surface-accent space-y-4 rounded-m3-lg p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex-1 space-y-2">
              <div
                :if={@media_state == "pending"}
                class="text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted"
              >
                Queue #{Map.get(@queue_positions, media_item.id, "-")}
              </div>
              <div class="flex items-start gap-2">
                <.icon
                  :if={media_item.last_error}
                  name="hero-exclamation-circle-solid"
                  class="theme-status-error mt-0.5 shrink-0"
                />
                <div class="min-w-0">
                  <.subtle_link href={~p"/sources/#{@source.id}/media/#{media_item.id}"}>
                    <span class="block whitespace-normal break-words font-medium text-theme-on-surface">
                      {media_item.title}
                    </span>
                  </.subtle_link>
                </div>
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-2">
              <.icon_button
                :if={@media_state != "downloaded"}
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
                icon_name="hero-stop-solid"
                variant="danger"
                class="h-10 w-10"
                phx-click="stop_download"
                phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
                phx-value-media-id={media_item.id}
                data-confirm="Are you sure you want to stop this download?"
                tooltip="Stop Download"
                tooltip_position="bottom-left"
              />
              <.icon_link href={~p"/sources/#{@source.id}/media/#{media_item.id}/edit"} icon="hero-pencil-square" />
            </div>
          </div>

          <div
            :if={media_item.last_error}
            class="theme-danger-panel whitespace-pre-wrap break-words rounded-m3-sm p-3 text-xs"
          >
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
            <div :if={@media_state == "other"} class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Prevent Download</dt>
              <dd class="text-right text-theme-on-surface">
                <.icon name={if media_item.prevent_download, do: "hero-check", else: "hero-x-mark"} />
              </dd>
            </div>
            <div :if={@media_state == "other"} class="flex items-start justify-between gap-3">
              <dt class="text-theme-on-surface-muted">Excluded Reason</dt>
              <dd class="max-w-[60%] text-right text-theme-on-surface">{excluded_reason(media_item, @source)}</dd>
            </div>
          </dl>
        </article>
      </div>

      <div class="hidden md:block">
        <.table rows={@records}>
          <:col :let={media_item} :if={@media_state == "pending"} label="#" class="w-16 text-center">
            {Map.get(@queue_positions, media_item.id, "-")}
          </:col>

          <:col :let={media_item} label="Title" class="max-w-sm">
            <section class="space-y-2">
              <div class="flex items-start space-x-1 gap-2">
                <.icon :if={media_item.last_error} name="hero-exclamation-circle-solid" class="theme-status-error shrink-0" />
                <.icon_button
                  :if={@media_state != "downloaded"}
                  icon_name="hero-arrow-down-tray"
                  class="h-10 w-10"
                  phx-click="force_download"
                  phx-value-media-id={media_item.id}
                  data-confirm="Are you sure you want to force a download of this media?"
                  tooltip="Force Download"
                  tooltip_position="bottom-left"
                />
                <.subtle_link href={~p"/sources/#{@source.id}/media/#{media_item.id}"}>
                  <span class="block whitespace-normal break-words">{media_item.title}</span>
                </.subtle_link>
              </div>

              <div :if={media_item.last_error} class="theme-status-error whitespace-pre-wrap break-words text-xs">
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

          <:col :let={media_item} label="Upload Date">{DateTime.to_date(media_item.uploaded_at)}</:col>

          <:col :let={media_item} label="Size / Progress">
            <.progress_details media_item={media_item} task={Map.get(@tasks_by_media_item_id, media_item.id)} />
          </:col>

          <:col :let={media_item} label="Action">
            <.icon_button
              :if={Map.has_key?(@tasks_by_media_item_id, media_item.id)}
              icon_name="hero-stop-solid"
              variant="danger"
              class="h-10 w-10"
              phx-click="stop_download"
              phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
              phx-value-media-id={media_item.id}
              data-confirm="Are you sure you want to stop this download?"
              tooltip="Stop Download"
              tooltip_position="bottom-left"
            />
            <span :if={!Map.has_key?(@tasks_by_media_item_id, media_item.id)} class="text-theme-on-surface-muted">-</span>
          </:col>
          <:col :let={media_item} label="" class="align-middle text-right">
            <div class="flex justify-end">
              <.icon_link
                href={~p"/sources/#{@source.id}/media/#{media_item.id}/edit"}
                icon="hero-pencil-square"
                class="mr-4"
              />
            </div>
          </:col>
        </.table>
      </div>

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
    pagination_attrs = fetch_pagination_attributes(base_query, page, nil, media_state)

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
    new_assigns = fetch_pagination_attributes(assigns.base_query, new_page, assigns.search_term, assigns.media_state)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("search_term", params, socket) do
    search_term = Map.get(params, "q", nil)

    new_assigns =
      fetch_pagination_attributes(socket.assigns.base_query, 1, search_term, socket.assigns.media_state)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("force_download", %{"media-id" => media_id}, socket) do
    media_item = Media.get_media_item!(media_id)
    MediaDownloadWorker.kickoff_with_task(media_item, %{force: true, reset_last_error: true})
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
    new_assigns =
      fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term, assigns.media_state)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_info(%{topic: "job:state", event: "change", payload: payload}, %{assigns: assigns} = socket)
      when is_map(payload) do
    if refresh_required?(assigns, payload) do
      new_assigns =
        fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term, assigns.media_state)

      {:noreply, assign(socket, new_assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: assigns} = socket) do
    new_assigns =
      fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term, assigns.media_state)

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

  defp fetch_pagination_attributes(base_query, page, "", media_state),
    do: fetch_pagination_attributes(base_query, page, nil, media_state)

  defp fetch_pagination_attributes(base_query, page, nil, media_state) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    if media_state == "pending" do
      records =
        base_query
        |> order_pending_media()
        |> fetch_records(page)
        |> Repo.all()

      build_pagination_attrs(
        %{
          page: page,
          total_pages: total_pages,
          records: records,
          search_term: nil,
          total_record_count: total_record_count,
          filtered_record_count: total_record_count
        },
        media_state,
        base_query
      )
    else
      records =
        fetch_records(base_query, page)
        |> order_by(desc: :uploaded_at)
        |> Repo.all()

      build_pagination_attrs(
        %{
          page: page,
          total_pages: total_pages,
          records: records,
          search_term: nil,
          total_record_count: total_record_count,
          filtered_record_count: total_record_count
        },
        media_state,
        base_query
      )
    end
  end

  defp fetch_pagination_attributes(base_query, page, search_term, media_state) do
    filtered_base_query = filtered_base_query(base_query, search_term)

    total_record_count = Repo.aggregate(base_query, :count, :id)
    filtered_record_count = Repo.aggregate(filtered_base_query, :count, :id)
    total_pages = max(ceil(filtered_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    if media_state == "pending" do
      records =
        filtered_base_query
        |> order_pending_media()
        |> fetch_records(page)
        |> Repo.all()

      build_pagination_attrs(
        %{
          page: page,
          total_pages: total_pages,
          records: records,
          search_term: search_term,
          total_record_count: total_record_count,
          filtered_record_count: filtered_record_count
        },
        media_state,
        filtered_base_query
      )
    else
      records =
        fetch_records(filtered_base_query, page)
        |> order_by(desc: fragment("rank"), desc: :uploaded_at)
        |> Repo.all()

      build_pagination_attrs(
        %{
          page: page,
          total_pages: total_pages,
          records: records,
          search_term: search_term,
          total_record_count: total_record_count,
          filtered_record_count: filtered_record_count
        },
        media_state,
        filtered_base_query
      )
    end
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
        if source.selection_mode == :manual do
          "Not selected in delayed downloads mode"
        else
          "Prevented"
        end

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

  defp build_pagination_attrs(attrs, media_state, queue_base_query) do
    tasks_by_media_item_id = fetch_download_tasks(attrs.records)
    ordered_records = order_records_for_display(attrs.records, tasks_by_media_item_id, media_state)

    attrs
    |> Map.put(:records, ordered_records)
    |> Map.put(:tasks_by_media_item_id, tasks_by_media_item_id)
    |> Map.put(:queue_positions, build_queue_positions(queue_base_query, ordered_records, media_state))
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

  defp order_records_for_display(records, tasks_by_media_item_id, "pending") do
    Enum.sort_by(records, fn media_item ->
      queue_sort_key(media_item, Map.get(tasks_by_media_item_id, media_item.id))
    end)
  end

  defp order_records_for_display(records, _tasks_by_media_item_id, _media_state), do: records

  defp build_queue_positions(base_query, records, "pending") do
    records
    |> Enum.map(& &1.id)
    |> then(fn record_ids ->
      base_query
      |> active_pending_media_ids_query()
      |> Repo.all()
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {media_item_id, position}, acc ->
        if media_item_id in record_ids, do: Map.put(acc, media_item_id, position), else: acc
      end)
    end)
  end

  defp build_queue_positions(_base_query, _records, _media_state), do: %{}

  defp active_pending_media_ids_query(base_query) do
    latest_task_ids = latest_active_download_task_ids_query()

    from(media_item in exclude(base_query, :select),
      join: latest_task in subquery(latest_task_ids),
      on: latest_task.media_item_id == media_item.id,
      join: task in Task,
      on: task.id == latest_task.task_id,
      join: job in Oban.Job,
      on: job.id == task.job_id,
      order_by: [
        asc: fragment("CASE WHEN ? = 'executing' THEN 0 ELSE 1 END", job.state),
        asc: task.inserted_at,
        desc: media_item.uploaded_at,
        desc: media_item.id
      ],
      select: media_item.id
    )
  end

  defp order_pending_media(base_query) do
    latest_task_ids = latest_active_download_task_ids_query()

    from(media_item in exclude(base_query, :order_by),
      left_join: latest_task in subquery(latest_task_ids),
      on: latest_task.media_item_id == media_item.id,
      left_join: task in Task,
      on: task.id == latest_task.task_id,
      left_join: job in Oban.Job,
      on: job.id == task.job_id,
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? = 'executing' THEN 0 WHEN ? IS NOT NULL THEN 1 ELSE 2 END",
            job.state,
            task.id
          ),
        asc: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", task.inserted_at),
        asc: task.inserted_at,
        desc: media_item.uploaded_at,
        desc: media_item.id
      ]
    )
  end

  defp latest_active_download_task_ids_query do
    from(task in Task,
      join: job in assoc(task, :job),
      where: fragment("? LIKE ?", job.worker, ^"%.MediaDownloadWorker"),
      where: job.state in ^["available", "scheduled", "retryable", "executing"],
      where: not is_nil(task.media_item_id),
      group_by: task.media_item_id,
      select: %{media_item_id: task.media_item_id, task_id: max(task.id)}
    )
  end

  defp queue_sort_key(media_item, %Task{job: %{state: "executing"}, inserted_at: inserted_at}) do
    {0, sort_datetime_asc_key(inserted_at || media_item.uploaded_at), media_item.id}
  end

  defp queue_sort_key(media_item, %Task{inserted_at: inserted_at}) do
    {1, sort_datetime_asc_key(inserted_at || media_item.uploaded_at), media_item.id}
  end

  defp queue_sort_key(media_item, nil) do
    {2, sort_datetime_desc_key(media_item.uploaded_at), media_item.id}
  end

  defp sort_datetime_asc_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)
  defp sort_datetime_asc_key(_datetime), do: 9_999_999_999
  defp sort_datetime_desc_key(%DateTime{} = datetime), do: -DateTime.to_unix(datetime, :second)
  defp sort_datetime_desc_key(_datetime), do: 0

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
        waiting_size_label(task.progress_status)
        |> maybe_append_speed(speed_bytes)
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
      :progress_speed_bytes_per_second,
      :progress_updated_at
    ]
  end
end
