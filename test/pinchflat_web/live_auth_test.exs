defmodule PinchflatWeb.LiveAuthTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PinchflatWeb.Browse.BrowseLive

  setup do
    old_oidc = Application.get_env(:pinchflat, :oidc)
    on_exit(fn -> Application.put_env(:pinchflat, :oidc, old_oidc) end)
    Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test")
  end

  test "redirects a LiveView mount without an SSO session to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live_isolated(conn, BrowseLive)
  end

  test "mounts a LiveView with an SSO session", %{conn: conn} do
    conn = init_test_session(conn, %{sso_user: %{"sub" => "user"}})

    assert {:ok, _view, _html} = live_isolated(conn, BrowseLive)
  end

  test "protects the settings-changing upgrade component", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live_isolated(conn, Pinchflat.UpgradeButtonLive)
    refute Pinchflat.Settings.get!(:pro_enabled)
  end

  test "login renders without protected LiveViews", %{conn: conn} do
    conn = get(conn, "/auth/login")
    html = html_response(conn, 200)
    assert html =~ "Sign in"
    refute html =~ "upgradeForm"
    refute html =~ "data-phx-session"
  end

  test "mounts without a session when OIDC is disabled", %{conn: conn} do
    Application.put_env(:pinchflat, :oidc, nil)

    assert {:ok, _view, _html} = live_isolated(conn, BrowseLive)
  end
end
