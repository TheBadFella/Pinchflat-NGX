defmodule PinchflatWeb.PlugsTest do
  use PinchflatWeb.ConnCase

  alias PinchflatWeb.Plugs
  alias Pinchflat.Settings

  describe "maybe_basic_auth/2" do
    setup do
      old_username = Application.get_env(:pinchflat, :basic_auth_username)
      old_password = Application.get_env(:pinchflat, :basic_auth_password)
      old_expose_feed_endpoints = Application.get_env(:pinchflat, :expose_feed_endpoints)

      on_exit(fn ->
        Application.put_env(:pinchflat, :basic_auth_username, old_username)
        Application.put_env(:pinchflat, :basic_auth_password, old_password)
        Application.put_env(:pinchflat, :expose_feed_endpoints, old_expose_feed_endpoints)
      end)

      :ok
    end

    test "uses basic auth when expose_feed_endpoints is false" do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")
      Application.put_env(:pinchflat, :expose_feed_endpoints, false)

      conn = Plugs.maybe_basic_auth(build_conn(), [])

      assert conn.status == 401
      assert {"www-authenticate", "Basic realm=\"Pinchflat\""} in conn.resp_headers
    end

    test "supplying the correct username and password allows access" do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")
      Application.put_env(:pinchflat, :expose_feed_endpoints, false)

      encoded_auth = Plug.BasicAuth.encode_basic_auth("user", "pass")

      conn =
        build_conn()
        |> put_req_header("authorization", encoded_auth)
        |> Plugs.maybe_basic_auth([])

      # nil here means the response is unset, but that's good. It just means we're moving to the next stage
      assert conn.status == nil
    end

    test "does not use basic auth when expose_feed_endpoints is true" do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")
      Application.put_env(:pinchflat, :expose_feed_endpoints, true)

      conn = Plugs.maybe_basic_auth(build_conn(), [])

      assert conn.status == nil
    end

    test "does not use basic auth when username/password aren't set" do
      Application.put_env(:pinchflat, :basic_auth_username, nil)
      Application.put_env(:pinchflat, :basic_auth_password, nil)
      Application.put_env(:pinchflat, :expose_feed_endpoints, false)

      conn = Plugs.maybe_basic_auth(build_conn(), [])

      # nil here means the response is unset, but that's good. It just means we're moving to the next stage
      assert conn.status == nil
    end
  end

  describe "basic_auth/2" do
    setup do
      old_username = Application.get_env(:pinchflat, :basic_auth_username)
      old_password = Application.get_env(:pinchflat, :basic_auth_password)

      on_exit(fn ->
        Application.put_env(:pinchflat, :basic_auth_username, old_username)
        Application.put_env(:pinchflat, :basic_auth_password, old_password)
      end)

      :ok
    end

    test "uses basic auth when both username and password are set", %{conn: conn} do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn = Plugs.basic_auth(conn, [])

      assert conn.status == 401
      assert {"www-authenticate", "Basic realm=\"Pinchflat\""} in conn.resp_headers
    end

    test "providing the username and password allows access", %{conn: conn} do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn =
        conn
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("user", "pass"))
        |> Plugs.basic_auth([])

      # nil here means the response is unset, but that's good. It just means we're moving to the next stage
      assert conn.status == nil
    end

    test "does not use basic auth when either username or password is not set", %{conn: conn} do
      Application.put_env(:pinchflat, :basic_auth_username, nil)
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn = Plugs.basic_auth(conn, [])

      assert conn.status == nil
    end

    test "treats empty strings as not being set when using basic auth", %{conn: conn} do
      Application.put_env(:pinchflat, :basic_auth_username, "")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn = Plugs.basic_auth(conn, [])

      assert conn.status == nil
    end
  end

  describe "browser_basic_auth/2" do
    setup do
      old_oidc = Application.get_env(:pinchflat, :oidc)
      old_username = Application.get_env(:pinchflat, :basic_auth_username)
      old_password = Application.get_env(:pinchflat, :basic_auth_password)

      on_exit(fn ->
        Application.put_env(:pinchflat, :oidc, old_oidc)
        Application.put_env(:pinchflat, :basic_auth_username, old_username)
        Application.put_env(:pinchflat, :basic_auth_password, old_password)
      end)

      :ok
    end

    test "no-ops when OIDC SSO is enabled even with credentials set", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test")
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn = Plugs.browser_basic_auth(conn, [])

      # nil here means the response is unset, but that's good. It just means we're moving to the next stage
      assert conn.status == nil
    end

    test "falls through to basic auth when SSO is disabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, nil)
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn = Plugs.browser_basic_auth(conn, [])

      assert conn.status == 401
      assert {"www-authenticate", "Basic realm=\"Pinchflat\""} in conn.resp_headers
    end
  end

  describe "require_sso_auth/2" do
    setup do
      old_oidc = Application.get_env(:pinchflat, :oidc)

      on_exit(fn ->
        Application.put_env(:pinchflat, :oidc, old_oidc)
      end)

      :ok
    end

    test "passes through when oidc is not configured", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, nil)

      conn = Plugs.require_sso_auth(conn, [])

      # nil here means the response is unset, but that's good. It just means we're moving to the next stage
      assert conn.status == nil
      refute conn.halted
    end

    test "redirects to /auth/login with the current path and halts when enabled and no session user", %{
      session_conn: conn
    } do
      Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test", client_id: "id", client_secret: "secret")

      conn = %{conn | request_path: "/sources"} |> Plugs.require_sso_auth([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/login?redirect_to=%2Fsources"
    end

    test "preserves the query string in the login redirect", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test", client_id: "id", client_secret: "secret")

      conn = %{conn | request_path: "/sources", query_string: "tab=history"} |> Plugs.require_sso_auth([])

      assert redirected_to(conn) == "/auth/login?redirect_to=%2Fsources%3Ftab%3Dhistory"
    end

    test "passes through and assigns :sso_user when the session has a user", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test", client_id: "id", client_secret: "secret")

      conn =
        conn
        |> put_session(PinchflatWeb.OIDC.session_key(), %{sub: "user-123"})
        |> Plugs.require_sso_auth([])

      refute conn.halted
      assert conn.assigns.sso_user == %{sub: "user-123"}
    end
  end

  describe "basic_auth/2 with SSO enabled" do
    test "still applies basic auth to feed routes when oidc is configured", %{conn: conn} do
      old_oidc = Application.get_env(:pinchflat, :oidc)
      old_username = Application.get_env(:pinchflat, :basic_auth_username)
      old_password = Application.get_env(:pinchflat, :basic_auth_password)

      on_exit(fn ->
        Application.put_env(:pinchflat, :oidc, old_oidc)
        Application.put_env(:pinchflat, :basic_auth_username, old_username)
        Application.put_env(:pinchflat, :basic_auth_password, old_password)
      end)

      Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test", client_id: "id", client_secret: "secret")
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      conn = Plugs.basic_auth(conn, [])

      assert conn.status == 401
      assert {"www-authenticate", "Basic realm=\"Pinchflat\""} in conn.resp_headers
    end
  end

  describe "allow_iframe_embed/2" do
    test "deletes the x-frame-options header", %{conn: conn} do
      conn = put_resp_header(conn, "x-frame-options", "DENY")
      assert ["DENY"] = get_resp_header(conn, "x-frame-options")

      conn = Plugs.allow_iframe_embed(conn, [])

      assert [] = get_resp_header(conn, "x-frame-options")
    end
  end

  describe "token_protected_route/2" do
    test "allows access when the route token is correct", %{conn: conn} do
      route_token = Settings.get!(:route_token)
      conn = %{conn | query_params: %{"route_token" => route_token}}

      conn = Plugs.token_protected_route(conn, [])

      # nil here means the response is unset, but that's good. It just means we're moving to the next stage
      assert conn.status == nil
    end

    test "does not allow access when the route token is incorrect", %{conn: conn} do
      conn = %{conn | query_params: %{"route_token" => "incorrect"}}

      conn = Plugs.token_protected_route(conn, [])

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "does not allow access when the route token is missing", %{conn: conn} do
      conn = %{conn | query_params: %{}}

      conn = Plugs.token_protected_route(conn, [])

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end
  end
end
