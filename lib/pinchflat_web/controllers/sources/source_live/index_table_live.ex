defmodule PinchflatWeb.Sources.SourceLive.IndexTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery
  use Pinchflat.Sources.SourcesQuery

  import PinchflatWeb.CustomComponents.DatePicker, only: [date_picker: 1]
  import PinchflatWeb.Helpers.SortingHelpers
  import PinchflatWeb.Helpers.PaginationHelpers

  alias Pinchflat.Database
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias PinchflatWeb.Sources.SourceHTML

  @default_view_mode :table

  def source_download_mode_label(%{selection_mode: :manual}), do: "Delayed Downloads"
  def source_download_mode_label(%{selection_mode: _selection_mode}), do: "Automatic Downloads"

  @doc """
  Returns the poster URL used by the source library card.

  The endpoint applies the same artwork fallback as the podcast feed, so a
  source poster, fanart image, or downloaded media thumbnail can be used.
  """
  def source_poster_url(source), do: source |> source_struct() |> SourceHTML.poster_preview_url()

  @doc """
  Returns the initials used while a source poster is unavailable.
  """
  def source_initials(source), do: SourceHTML.source_initials(source)
  defdelegate cutoff_date_presets(), to: SourceHTML

  @doc """
  Describes source download progress without treating an unknown or empty
  denominator as complete.

  Returns a map with `:state`, `:label`, and either a `:percent` or `nil`.
  """
  def source_progress(%{media_count: nil}),
    do: %{state: :unknown, label: "Progress unavailable: total unknown", percent: nil}

  def source_progress(%{media_count: 0}), do: %{state: :empty, label: "No indexed media yet", percent: 0}

  def source_progress(%{media_count: total, downloaded_count: downloaded}) when total > 0 do
    percent = min(div(downloaded * 100, total), 100)
    %{state: :known, label: "#{downloaded} of #{total} indexed items downloaded", percent: percent}
  end

  def mount(_params, session, socket) do
    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("job:state")
      PinchflatWeb.Endpoint.subscribe("job:progress")
    end

    limit = session["results_per_page"]

    initial_params =
      Map.merge(
        %{
          sort_key: session["initial_sort_key"],
          sort_direction: session["initial_sort_direction"],
          view_mode: normalize_view_mode(session["initial_view_mode"]),
          refresh_pending: false,
          selected_ids: MapSet.new(),
          media_profiles: Enum.reject(Profiles.list_media_profiles(), & &1.marked_for_deletion_at),
          timezone: Application.fetch_env!(:pinchflat, :timezone)
        },
        get_pagination_attributes(sources_query(), 1, limit)
      )

    socket
    |> assign(initial_params)
    |> set_sources()
    |> then(&{:ok, &1})
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    new_page = update_page_number(assigns.page, direction, assigns.total_pages)

    socket
    |> assign(:selected_ids, MapSet.new())
    |> assign(get_pagination_attributes(sources_query(), new_page, assigns.limit))
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def handle_event("sort_update", %{"sort_key" => sort_key}, %{assigns: assigns} = socket) do
    new_sort_key = String.to_existing_atom(sort_key)

    new_params = %{
      sort_key: new_sort_key,
      sort_direction: get_sort_direction(assigns.sort_key, new_sort_key, assigns.sort_direction)
    }

    socket
    |> assign(:selected_ids, MapSet.new())
    |> assign(new_params)
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def handle_event("view_change", %{"view" => view_mode}, socket) do
    {:noreply, assign(socket, :view_mode, normalize_view_mode(view_mode))}
  end

  def handle_event("select_page", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new(socket.assigns.sources, &to_string(&1.id)))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("toggle_source_selection", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    if Enum.any?(socket.assigns.sources, &(to_string(&1.id) == id)) do
      selected = if MapSet.member?(selected, id), do: MapSet.delete(selected, id), else: MapSet.put(selected, id)
      {:noreply, assign(socket, :selected_ids, selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, throttled_set_sources(socket)}
  end

  def handle_info(%{topic: "job:progress", event: "update"}, socket) do
    {:noreply, throttled_set_sources(socket)}
  end

  def handle_info(:throttled_refresh, socket) do
    {:noreply, socket |> assign(:refresh_pending, false) |> set_sources()}
  end

  def handle_info({:source_enabled_updated, _source_id}, socket) do
    {:noreply, set_sources(socket)}
  end

  defp sort_attr(:pending_count), do: dynamic([s, mp, dl, pe], coalesce(pe.pending_count, 0))
  defp sort_attr(:downloaded_count), do: dynamic([s, mp, dl], coalesce(dl.downloaded_count, 0))
  defp sort_attr(:media_size_bytes), do: dynamic([s, mp, dl], coalesce(dl.media_size_bytes, 0))
  defp sort_attr(:media_profile_name), do: dynamic([s, mp], fragment("LOWER(?)", mp.name))

  defp sort_attr(:custom_name) do
    if Database.postgres?() do
      dynamic([s], fragment("LOWER(?)", s.custom_name))
    else
      dynamic([s], fragment("? COLLATE NOCASE", s.custom_name))
    end
  end

  defp sort_attr(:enabled), do: dynamic([s], s.enabled)
  defp sort_attr(:collection_type), do: dynamic([s], s.collection_type)

  defp normalize_view_mode(mode) when mode in [:grid, "grid"], do: :grid
  defp normalize_view_mode(_mode), do: @default_view_mode

  defp source_struct(%Source{} = source), do: source
  defp source_struct(source), do: struct(Source, source)

  defp set_sources(%{assigns: assigns} = socket) do
    sources =
      sources_query()
      |> order_by(^[{assigns.sort_direction, sort_attr(assigns.sort_key)}, asc: :id])
      |> limit(^assigns.limit)
      |> offset(^assigns.offset)
      |> Repo.all()

    visible_ids = MapSet.new(sources, &to_string(&1.id))
    assign(socket, %{sources: sources, selected_ids: MapSet.intersection(assigns.selected_ids, visible_ids)})
  end

  @refresh_throttle_ms 500

  defp throttled_set_sources(socket) do
    if Map.get(socket.assigns, :refresh_pending, false) do
      socket
    else
      Process.send_after(self(), :throttled_refresh, @refresh_throttle_ms)

      socket
      |> assign(:refresh_pending, true)
      |> set_sources()
    end
  end

  defp sources_query do
    downloaded_subquery =
      from(
        m in MediaItem,
        select: %{downloaded_count: count(m.id), source_id: m.source_id, media_size_bytes: sum(m.media_size_bytes)},
        where: ^MediaQuery.downloaded(),
        group_by: m.source_id
      )

    pending_subquery =
      from(
        m in MediaItem,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        select: %{pending_count: count(m.id), source_id: m.source_id},
        where: ^MediaQuery.pending(),
        group_by: m.source_id
      )

    indexed_subquery =
      from(
        m in MediaItem,
        select: %{media_count: count(m.id), source_id: m.source_id},
        group_by: m.source_id
      )

    from s in Source,
      as: :source,
      inner_join: mp in assoc(s, :media_profile),
      left_join: d in subquery(downloaded_subquery),
      on: d.source_id == s.id,
      left_join: p in subquery(pending_subquery),
      on: p.source_id == s.id,
      left_join: i in subquery(indexed_subquery),
      on: i.source_id == s.id,
      left_join: md in assoc(s, :metadata),
      where: is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at),
      preload: [media_profile: mp, metadata: md],
      select: map(s, ^Source.__schema__(:fields)),
      select_merge: %{
        downloaded_count: coalesce(d.downloaded_count, 0),
        pending_count: coalesce(p.pending_count, 0),
        media_size_bytes: coalesce(d.media_size_bytes, 0),
        media_count: coalesce(i.media_count, 0)
      }
  end
end
