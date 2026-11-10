defmodule PinchflatWeb.Components.MediaComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CustomComponents.MediaComponents

  @media_item %{uuid: "media-uuid-123", thumbnail_filepath: "/media/thumb.jpg", title: "A video"}

  test "renders a lazy-loaded image when the item has a thumbnail path" do
    html = render_component(&MediaComponents.media_thumbnail/1, media_item: @media_item)

    assert html =~ ~s(src="/media/media-uuid-123/episode_image")
    assert html =~ ~s(loading="lazy")
    assert html =~ ~s(decoding="async")
    assert html =~ "<img"
  end

  test "renders a placeholder without an image when there is no thumbnail path" do
    html =
      render_component(&MediaComponents.media_thumbnail/1,
        media_item: %{@media_item | thumbnail_filepath: nil}
      )

    refute html =~ "<img"
    assert html =~ ~s(data-icon="hero-film")
  end

  test "row size adds the fixed thumbnail width" do
    html =
      render_component(&MediaComponents.media_thumbnail/1, media_item: @media_item, size: "row")

    assert html =~ "w-28"
  end
end
