defmodule Pinchflat.Pages.DeletionHistoryLive do
  @moduledoc """
  The Deletions tab of the home page's Media History: deleted sources and
  deleted media files, newest first, with what caused each deletion.
  """

  use PinchflatWeb, :live_view
  import Ecto.Query, warn: false

  alias Pinchflat.DeletionHistory
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias PinchflatWeb.CustomComponents.TextComponents

  @per_page 25

  def mount(_params, _session, socket) do
    {:ok, load_page(socket, 1)}
  end

  def handle_event("page_change", %{"direction" => direction}, socket) do
    page = if direction == "inc", do: socket.assigns.page + 1, else: socket.assigns.page - 1
    {:noreply, load_page(socket, page |> max(1) |> min(socket.assigns.total_pages))}
  end

  def handle_event("reload_page", _params, socket), do: {:noreply, load_page(socket, socket.assigns.page)}

  def render(%{events: []} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
      <p class="ml-2">No deletions recorded yet. Deleted sources and media files will be listed here.</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="mb-4 flex flex-wrap items-center gap-3">
      <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
      <p class="text-sm text-theme-on-surface-muted">
        Deleted sources and media files, newest first. A deleted source's URL is kept so you can add it again.
      </p>
    </div>
    <.table rows={@events} compact>
      <:col :let={event} label="Deleted At">{format_datetime(event.inserted_at)}</:col>
      <:col :let={event} label="What" class="max-w-sm">
        <span class="block break-words font-medium">{subject(event)}</span>
        <span class="block text-sm text-theme-on-surface-muted">{detail(event)}</span>
      </:col>
      <:col :let={event} label="Cause">{reason_label(event.reason)}</:col>
      <:col :let={event} label="Source" class="max-w-sm">
        <.subtle_link :if={event.source_id in @existing_source_ids} href={~p"/sources/#{event.source_id}"}>
          {event.source_name}
        </.subtle_link>
        <span :if={event.source_id not in @existing_source_ids} class="block break-words">
          {event.source_name}
          <span :if={event.source_url} class="block break-all text-sm text-theme-on-surface-muted">
            {event.source_url}
          </span>
        </span>
      </:col>
    </.table>
    <section class="mt-6 flex justify-center">
      <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
    </section>
    """
  end

  defp load_page(socket, page) do
    {events, total_pages} = DeletionHistory.list_page(page, @per_page)
    source_ids = events |> Enum.map(& &1.source_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    existing_source_ids =
      if source_ids == [],
        do: [],
        else: Repo.all(from s in Source, where: s.id in ^source_ids, select: s.id)

    assign(socket, events: events, page: page, total_pages: total_pages, existing_source_ids: existing_source_ids)
  end

  defp subject(%{kind: :source} = event), do: event.source_name || "Source ##{event.source_id}"
  defp subject(event), do: event.media_title || event.media_id || "Media item ##{event.media_item_id}"

  defp detail(%{kind: :source} = event) do
    type = if event.collection_type, do: String.capitalize(event.collection_type), else: "Source"
    items = "#{event.item_count || 0} #{if event.item_count == 1, do: "media item", else: "media items"}"
    files = if event.files_deleted, do: "files deleted", else: "files kept on disk"

    "#{type} source deleted with #{items}, #{files}"
  end

  defp detail(_event), do: "Media files deleted; the media item is kept"

  defp reason_label(:user), do: "You deleted it"
  defp reason_label(:retention), do: "Retention period ended"
  defp reason_label(:download_cutoff), do: "Published before the download cutoff"
  defp reason_label(:keep_newest), do: "Outside the newest videos to keep"
  defp reason_label(:media_profile_deleted), do: "Its media profile was deleted"

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end
end
