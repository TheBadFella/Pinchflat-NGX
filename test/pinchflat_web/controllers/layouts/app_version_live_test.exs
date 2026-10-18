defmodule PinchflatWeb.AppVersionLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings
  alias Pinchflat.AppVersionLive
  alias Pinchflat.AppReleaseCheck

  setup do
    previous_check = Application.get_env(:pinchflat, :app_release_check)
    previous_track = Application.get_env(:pinchflat, :build_track)
    previous_sha = Application.get_env(:pinchflat, :build_sha)

    Application.put_env(:pinchflat, :app_release_check, true)
    Application.put_env(:pinchflat, :build_track, "stable")
    Application.delete_env(:pinchflat, :build_sha)
    AppReleaseCheck.clear_cache()

    on_exit(fn ->
      AppReleaseCheck.clear_cache()
      Application.put_env(:pinchflat, :app_release_check, previous_check)

      if previous_track == nil do
        Application.delete_env(:pinchflat, :build_track)
      else
        Application.put_env(:pinchflat, :build_track, previous_track)
      end

      if previous_sha == nil do
        Application.delete_env(:pinchflat, :build_sha)
      else
        Application.put_env(:pinchflat, :build_sha, previous_sha)
      end
    end)

    :ok
  end

  test "renders Latest and the configured yt-dlp policy chip", %{conn: conn} do
    Settings.set(yt_dlp_update_policy: "nightly")

    expect(HTTPClientMock, :get, fn _url, _headers ->
      {:ok, Jason.encode!(%{"tag_name" => AppReleaseCheck.current_version()})}
    end)

    {:ok, _view, html} = live_isolated(conn, AppVersionLive)

    assert html =~ "Pinchflat-ngx"
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

  test "renders Dev chip, short sha tooltip, and commit link when running dev build with commit sha", %{conn: conn} do
    Application.put_env(:pinchflat, :build_track, "dev")
    Application.put_env(:pinchflat, :build_sha, "1b7c57fe3ea7c0f0e8ad2749b342e44eced7c85c")

    {:ok, _view, html} = live_isolated(conn, AppVersionLive)

    assert html =~ "Pinchflat-ngx"
    assert html =~ "Dev"
    assert html =~ "theme-badge-dev"
    refute html =~ ">Latest<"
    assert html =~ "dev-1b7c57f"
    assert html =~ "https://github.com/TheBadFella/pinchflat-ngx/commit/1b7c57fe3ea7c0f0e8ad2749b342e44eced7c85c"
  end

  test "renders Dev chip and repo link when running dev build without commit sha", %{conn: conn} do
    Application.put_env(:pinchflat, :build_track, "dev")
    Application.delete_env(:pinchflat, :build_sha)

    {:ok, _view, html} = live_isolated(conn, AppVersionLive)

    assert html =~ "Pinchflat-ngx"
    assert html =~ "Dev"
    assert html =~ "theme-badge-dev"
    refute html =~ ">Latest<"
    assert html =~ ~s(title="dev")
    assert html =~ "https://github.com/TheBadFella/pinchflat-ngx"
  end
end
