defmodule PinchflatWeb.Settings.YtDlpVersionLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings.YtDlpVersionLive

  describe "initial rendering" do
    test "renders the policy select", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, YtDlpVersionLive, session: create_session("stable", nil))

      assert html =~ ~s(name="setting[yt_dlp_update_policy]")
    end

    test "hides the pinned version field unless the policy is pinned", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, YtDlpVersionLive, session: create_session("stable", nil))

      refute html =~ ~s(name="setting[yt_dlp_pinned_version]")
    end

    test "shows the pinned version field when the policy is pinned", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, YtDlpVersionLive, session: create_session("pinned", "2025.12.08"))

      assert html =~ ~s(name="setting[yt_dlp_pinned_version]")
      assert html =~ ~s(value="2025.12.08")
    end
  end

  describe "changing the policy" do
    test "reveals the pinned version field", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive, session: create_session("stable", nil))

      html = render_change(view, "policy_changed", %{"setting" => %{"yt_dlp_update_policy" => "pinned"}})

      assert html =~ ~s(name="setting[yt_dlp_pinned_version]")
    end
  end

  describe "checking a pinned version" do
    test "shows a checkmark when the version exists", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:ok, "{}"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive, session: create_session("pinned", "2025.12.08"))

      html = render_click(view, "check_version")

      assert html =~ "hero-check"
    end

    test "shows an x-mark when the version does not exist", %{conn: conn} do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, "not found"} end)

      {:ok, view, _html} = live_isolated(conn, YtDlpVersionLive, session: create_session("pinned", "9999.99.99"))

      html = render_click(view, "check_version")

      assert html =~ "hero-x-mark"
    end
  end

  defp create_session(policy, pinned_version) do
    %{"policy" => policy, "pinned_version" => pinned_version}
  end
end
