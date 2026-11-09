defmodule PinchflatWeb.CustomComponents.MediaComponents do
  @moduledoc false
  use Phoenix.Component
  use PinchflatWeb, :verified_routes

  alias PinchflatWeb.CoreComponents

  @doc """
  Renders a media item thumbnail with a decorative placeholder fallback.

  The image is only requested when the item has a stored thumbnail filepath.
  Missing files are handled in the browser so rendering never stats a media
  share per row.
  """
  attr :media_item, :map, required: true
  attr :size, :string, default: "card"
  attr :class, :string, default: nil

  def media_thumbnail(assigns) do
    assigns = assign(assigns, :has_thumbnail?, thumbnail?(assigns.media_item))

    ~H"""
    <div
      class={[
        "aspect-video overflow-hidden rounded-m3-md bg-theme-surface-4",
        @size == "row" && "w-28 shrink-0",
        @size == "card" && "w-full",
        @class
      ]}
      x-data="{ failed: false }"
    >
      <%= if @has_thumbnail? do %>
        <img
          src={~p"/media/#{@media_item.uuid}/episode_image"}
          alt=""
          loading="lazy"
          decoding="async"
          class="h-full w-full object-cover"
          x-show="!failed"
          x-on:error="failed = true"
        />
        <div
          class="flex h-full w-full items-center justify-center text-theme-on-surface-muted"
          x-show="failed"
          x-cloak
        >
          <CoreComponents.icon name="hero-film" class="h-8 w-8" aria-hidden="true" />
        </div>
      <% else %>
        <div class="flex h-full w-full items-center justify-center text-theme-on-surface-muted">
          <CoreComponents.icon name="hero-film" class="h-8 w-8" aria-hidden="true" />
        </div>
      <% end %>
    </div>
    """
  end

  defp thumbnail?(%{thumbnail_filepath: path}) when is_binary(path) and path != "", do: true
  defp thumbnail?(_media_item), do: false
end
