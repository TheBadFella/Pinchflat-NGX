defmodule PinchflatWeb.AppVersionLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings
  alias Pinchflat.AppVersionLive
  alias Pinchflat.AppReleaseCheck

  setup do
    previous = Application.get_env(:pinchflat, :app_release_check)
    Application.put_env(:pinchflat, :app_release_check, true)
    AppReleaseCheck.clear_cache()

    on_exit(fn ->
      AppReleaseCheck.clear_cache()
      Application.put_env(:pinchflat, :app_release_check, previous)
    end)

    :ok
  end

  test "renders Latest and the configured yt-dlp policy chip", %{conn: conn} do
    Settings.set(yt_dlp_update_policy: "nightly")

    expect(HTTPClientMock, :get, fn _url, _headers ->
      {:ok, Jason.encode!(%{"tag_name" => AppReleaseCheck.current_version()})}
    end)

    {:ok, _view, html} = live_isolated(conn, AppVersionLive)

    assert html =~ "PinchYT"
    assert html =~ "Latest"
    assert html =~ "yt-dlp"
    assert html =~ "Nightly"
  end

  test "shows the installed version and a warning when an update is available", %{conn: conn} do
    expect(HTTPClientMock, :get, fn _url, _headers ->
      {:ok, Jason.encode!(%{"tag_name" => "v9999.12.31"})}
    end)

    {:ok, _view, html} = live_isolated(conn, AppVersionLive)

    refute html =~ ">Latest<"
    assert html =~ AppReleaseCheck.current_version()
    assert html =~ "Update available: 9999.12.31"
    assert html =~ "!"
  end

  test "shows a Stable chip when that policy is selected", %{conn: conn} do
    Settings.set(yt_dlp_update_policy: "stable")

    expect(HTTPClientMock, :get, fn _url, _headers ->
      {:ok, Jason.encode!(%{"tag_name" => AppReleaseCheck.current_version()})}
    end)

    {:ok, _view, html} = live_isolated(conn, AppVersionLive)

    assert html =~ "Stable"
  end

  test "shows compact chips for the other yt-dlp policies", %{conn: conn} do
    stub(HTTPClientMock, :get, fn _url, _headers ->
      {:ok, Jason.encode!(%{"tag_name" => AppReleaseCheck.current_version()})}
    end)

    Settings.set(yt_dlp_update_policy: "nightly_frozen")
    {:ok, _view, html} = live_isolated(conn, AppVersionLive)
    assert html =~ "Frozen"

    Settings.set(yt_dlp_update_policy: "nightly_until_stable")
    {:ok, _view, html} = live_isolated(conn, AppVersionLive)
    assert html =~ "Until stable"

    Settings.set(yt_dlp_pinned_version: "2025.12.08")
    Settings.set(yt_dlp_update_policy: "pinned")
    {:ok, _view, html} = live_isolated(conn, AppVersionLive)
    assert html =~ "2025.12.08"
  end
end
