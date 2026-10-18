defmodule Pinchflat.Settings.MediaServerTestLiveTest do
  use PinchflatWeb.ConnCase, async: false
  import Mox
  import Phoenix.LiveViewTest

  alias Pinchflat.Settings

  setup :verify_on_exit!

  describe "MediaServerTestLive" do
    test "renders test button for specified server_type", %{conn: conn} do
      {:ok, view, html} =
        live_isolated(conn, Pinchflat.Settings.MediaServerTestLive, session: %{"server_type" => "plex"})

      assert html =~ "Test Connection"
      assert has_element?(view, "#test-plex-button")
    end

    test "handles successful connection test", %{conn: conn} do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          plex_enabled: true,
          plex_url: "http://plex.local:32400",
          plex_token: "tok"
        })

      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "/library/sections"
        {:ok, "<MediaContainer/>"}
      end)

      {:ok, view, _html} =
        live_isolated(conn, Pinchflat.Settings.MediaServerTestLive, session: %{"server_type" => "plex"})

      view
      |> element("#test-plex-button")
      |> render_click()

      assert render(view) =~ "Connected successfully"
      assert render(view) =~ "Success"
    end

    test "handles missing configuration", %{conn: conn} do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          plex_enabled: false,
          plex_url: nil,
          plex_token: nil
        })

      {:ok, view, _html} =
        live_isolated(conn, Pinchflat.Settings.MediaServerTestLive, session: %{"server_type" => "plex"})

      view
      |> element("#test-plex-button")
      |> render_click()

      assert render(view) =~ "Save URL &amp; token first"
    end

    test "handles connection failure", %{conn: conn} do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          jellyfin_enabled: true,
          jellyfin_url: "http://jelly.local:8096",
          jellyfin_api_key: "bad_key"
        })

      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "/System/Info"
        {:error, "HTTP request failed with status code 401"}
      end)

      {:ok, view, _html} =
        live_isolated(conn, Pinchflat.Settings.MediaServerTestLive, session: %{"server_type" => "jellyfin"})

      view
      |> element("#test-jellyfin-button")
      |> render_click()

      assert render(view) =~ "Failed"
      assert render(view) =~ "401"
    end
  end
end
