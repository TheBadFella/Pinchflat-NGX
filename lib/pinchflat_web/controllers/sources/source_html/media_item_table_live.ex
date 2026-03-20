defmodule PinchflatWeb.Sources.MediaItemTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Downloading.MediaDownloadWorker

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
          <section class="flex items-center space-x-1 gap-2">
            <.tooltip
              :if={media_item.last_error}
              tooltip={media_item.last_error}
              position="bottom-right"
              tooltip_class="w-64"
            >
              <.icon name="hero-exclamation-circle-solid" class="text-red-500" />
            </.tooltip>
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

  defp fetch_pagination_attributes(base_query, page, ""), do: fetch_pagination_attributes(base_query, page, nil)

  defp fetch_pagination_attributes(base_query, page, nil) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    records =
      fetch_records(base_query, page)
      |> order_by(desc: :uploaded_at)
      |> Repo.all()

    %{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: nil,
      total_record_count: total_record_count,
      filtered_record_count: total_record_count
    }
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

    %{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: search_term,
      total_record_count: total_record_count,
      filtered_record_count: filtered_record_count
    }
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
    [:id, :title, :uploaded_at, :prevent_download, :last_error, :duration_seconds, :livestream, :short_form_content]
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
end
