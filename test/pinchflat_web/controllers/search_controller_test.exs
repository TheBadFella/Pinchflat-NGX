defmodule PinchflatWeb.SearchControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  describe "show search" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/search")
      assert html_response(conn, 200) =~ "Results"
    end

    test "shows source, dates and download status for each result", %{conn: conn} do
      source = source_fixture(%{custom_name: "Slow Kitchen"})

      media_item_fixture(%{
        source_id: source.id,
        title: "Sourdough bread",
        media_filepath: "/tmp/bread.mp4",
        uploaded_at: ~U[2026-11-18 10:00:00Z],
        media_downloaded_at: ~U[2026-11-19 10:00:00Z]
      })

      media_item_fixture(%{source_id: source.id, title: "Flat bread", media_filepath: nil})

      html = conn |> get(~p"/search?q=bread") |> html_response(200)

      assert html =~ "Slow Kitchen"
      assert html =~ "published"
      assert html =~ "Downloaded"
      assert html =~ "Not downloaded"
    end
  end
end
