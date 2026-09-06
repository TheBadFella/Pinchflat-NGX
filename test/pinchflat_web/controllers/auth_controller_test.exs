defmodule PinchflatWeb.AuthControllerTest do
  @moduledoc """
  Tests for the optional OIDC/SSO auth flow and its interaction with the
  app's public routes (feeds, API, healthcheck).
  """

  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  alias PinchflatWeb.OIDC

  @oidc_config [
    issuer: "https://sso.test",
    client_id: "client_id",
    client_secret: "client_secret",
    scopes: "openid email profile",
    client_authentication_method: "client_secret_basic",
    provider_name: "TestProvider",
    redirect_uri: nil,
    # Static discovery document so assent never performs network requests
    # in tests; see PinchflatWeb.OIDC.provider_config/2 for the merge.
    openid_configuration: %{
      "issuer" => "https://sso.test",
      "authorization_endpoint" => "https://sso.test/authorize",
      "token_endpoint" => "https://sso.test/token",
      "jwks_uri" => "https://sso.test/jwks"
    },
    # HS256 lets the test sign the stub ID token with the client secret
    # instead of provisioning RSA keys.
    id_token_signed_response_alg: "HS256",
    http_adapter: PinchflatWeb.OIDCTestHTTPAdapter
  ]

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

  describe "login/2" do
    test "redirects home when SSO is disabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, nil)

      conn = get(conn, ~p"/auth/login")

      assert redirected_to(conn) == "/"
    end

    test "renders the login page with the provider name when enabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn = get(conn, ~p"/auth/login")

      assert html_response(conn, 200) =~ "Sign in with TestProvider"
    end
  end

  describe "request/2" do
    test "redirects to the provider's authorization endpoint with CSRF state and PKCE", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn = get(conn, ~p"/auth/oidc/request")

      assert redirected_to(conn) =~ "https://sso.test/authorize"

      uri = URI.parse(redirected_to(conn))
      params = URI.decode_query(uri.query)

      assert params["state"]
      assert params["code_challenge"]
      assert params["scope"] =~ "openid"

      assert get_session(conn, :oidc_session_params)["state"] == params["state"] ||
               get_session(conn, :oidc_session_params)[:state] == params["state"]
    end

    test "redirects to the login page with an error when authorization setup fails", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, Keyword.drop(@oidc_config, [:openid_configuration]))

      conn = get(conn, ~p"/auth/oidc/request")

      assert redirected_to(conn) == "/auth/login?error=1"
    end

    test "redirects home when SSO is disabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, nil)

      conn = get(conn, ~p"/auth/oidc/request")

      assert redirected_to(conn) == "/"
    end

    test "sanitizes the stored return_to path against open redirects", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      for redirect_to <- ["//evil.com", "/\\evil.com", "https://evil.com", "\\evil.com"] do
        conn = get(conn, ~p"/auth/oidc/request?redirect_to=#{redirect_to}")

        assert get_session(conn, :oidc_return_to) == "/"
      end

      conn = get(conn, ~p"/auth/oidc/request?redirect_to=/settings")

      assert get_session(conn, :oidc_return_to) == "/settings"
    end
  end

  describe "callback/2" do
    test "redirects to login with an error when no session params are present", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn = get(conn, ~p"/auth/oidc/callback?code=abc&state=tampered")

      assert redirected_to(conn) == "/auth/login?error=1"
    end

    test "redirects to login with an error when the state is tampered", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn =
        conn
        |> put_session(:oidc_session_params, %{state: "valid-state", code_verifier: "verifier", nonce: "nonce"})
        |> get(~p"/auth/oidc/callback?code=abc&state=tampered")

      assert redirected_to(conn) == "/auth/login?error=1"
    end

    test "completes the flow, stores the normalized user, and returns home", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      request_conn = get(conn, ~p"/auth/oidc/request")
      session_params = get_session(request_conn, :oidc_session_params)
      state = session_params["state"] || session_params[:state]
      nonce = session_params["nonce"] || session_params[:nonce]

      Process.put(:oidc_test_id_token, signed_id_token(%{"nonce" => nonce}))

      conn =
        request_conn
        |> recycle()
        |> get(~p"/auth/oidc/callback?code=auth-code&state=#{state}")

      assert redirected_to(conn) == "/"

      user = get_session(conn, OIDC.session_key())

      assert user.sub == "user-123"
      assert user.email == "user@example.com"
      assert user.name == "Test User"
      assert user.preferred_username == "testuser"
      assert user.picture == "https://sso.test/avatar.png"

      live_socket_id = get_session(conn, :live_socket_id)
      assert is_binary(live_socket_id)
      assert String.starts_with?(live_socket_id, "sso_sessions:")
    end

    test "rejects a validly-signed ID token with a mismatched nonce", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      request_conn = get(conn, ~p"/auth/oidc/request")
      session_params = get_session(request_conn, :oidc_session_params)
      state = session_params["state"] || session_params[:state]

      Process.put(:oidc_test_id_token, signed_id_token(%{"nonce" => "attacker-nonce"}))

      conn =
        request_conn
        |> recycle()
        |> get(~p"/auth/oidc/callback?code=auth-code&state=#{state}")

      assert redirected_to(conn) == "/auth/login?error=1"
      assert get_session(conn, OIDC.session_key()) == nil
    end

    test "rejects a validly-signed ID token with the wrong audience", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      request_conn = get(conn, ~p"/auth/oidc/request")
      session_params = get_session(request_conn, :oidc_session_params)
      state = session_params["state"] || session_params[:state]
      nonce = session_params["nonce"] || session_params[:nonce]

      Process.put(
        :oidc_test_id_token,
        signed_id_token(%{"aud" => "some-other-client", "nonce" => nonce})
      )

      conn =
        request_conn
        |> recycle()
        |> get(~p"/auth/oidc/callback?code=auth-code&state=#{state}")

      assert redirected_to(conn) == "/auth/login?error=1"
      assert get_session(conn, OIDC.session_key()) == nil
    end
  end

  describe "logout/2" do
    test "clears the session, disconnects live sockets, and redirects to the login page", %{session_conn: conn} do
      live_socket_id = "sso_sessions:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      Phoenix.PubSub.subscribe(Pinchflat.PubSub, live_socket_id)

      conn =
        conn
        |> put_session(OIDC.session_key(), %{sub: "user-123"})
        |> put_session(:live_socket_id, live_socket_id)
        |> delete(~p"/auth/logout")

      assert redirected_to(conn) == "/auth/login"
      assert get_session(conn, OIDC.session_key()) == nil
      assert get_session(conn, :live_socket_id) == nil
      assert_received %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works when SSO is disabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, nil)

      conn = delete(conn, ~p"/auth/logout")

      assert redirected_to(conn) == "/auth/login"
    end
  end

  describe "route gating regression" do
    test "browser routes require an SSO session when enabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn = get(conn, ~p"/")

      assert redirected_to(conn) == "/auth/login?redirect_to=%2F"
    end

    test "the login flow returns the user to the page that triggered it", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      gated =
        conn
        |> get(~p"/settings")

      assert redirected_to(gated) == "/auth/login?redirect_to=%2Fsettings"

      request_conn =
        gated
        |> recycle()
        |> get(~p"/auth/oidc/request?redirect_to=/settings")

      session_params = get_session(request_conn, :oidc_session_params)
      state = session_params["state"] || session_params[:state]
      nonce = session_params["nonce"] || session_params[:nonce]

      Process.put(:oidc_test_id_token, signed_id_token(%{"nonce" => nonce}))

      conn =
        request_conn
        |> recycle()
        |> get(~p"/auth/oidc/callback?code=auth-code&state=#{state}")

      assert redirected_to(conn) == "/settings"
    end

    test "browser routes render when enabled and the session has a user", %{session_conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn =
        conn
        |> put_session(OIDC.session_key(), %{sub: "user-123"})
        |> get(~p"/")

      assert html_response(conn, 200) =~ "Pinchflat"
    end

    test "feed routes stay reachable without an SSO session", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed" <> ".xml")

      assert conn.status == 200
      assert {"content-type", "application/rss+xml; charset=utf-8"} in conn.resp_headers
    end

    test "feed routes keep basic auth when SSO is enabled and BASIC_AUTH is set", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      old_username = Application.get_env(:pinchflat, :basic_auth_username)
      old_password = Application.get_env(:pinchflat, :basic_auth_password)

      # try/after (not on_exit) so the env is restored before any other test runs
      try do
        Application.put_env(:pinchflat, :basic_auth_username, "user")
        Application.put_env(:pinchflat, :basic_auth_password, "pass")

        source = source_fixture()

        unauthenticated = get(conn, ~p"/sources/#{source.uuid}/feed")
        assert unauthenticated.status == 401

        authenticated =
          build_conn()
          |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("user", "pass"))
          |> get(~p"/sources/#{source.uuid}/feed")

        assert authenticated.status == 200
      after
        Application.put_env(:pinchflat, :basic_auth_username, old_username)
        Application.put_env(:pinchflat, :basic_auth_password, old_password)
      end
    end

    test "API routes stay reachable without an SSO session", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn = get(conn, ~p"/api/media/recent_downloads")

      assert json_response(conn, 200)
    end

    test "the healthcheck stays reachable without an SSO session", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, @oidc_config)

      conn = get(conn, ~p"/healthcheck")

      assert conn.status == 200
    end

    test "browser routes stay open when SSO is disabled", %{conn: conn} do
      Application.put_env(:pinchflat, :oidc, nil)

      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~ "Pinchflat"
    end
  end

  defp signed_id_token(claim_overrides) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => "https://sso.test",
        "sub" => "user-123",
        "aud" => "client_id",
        "exp" => now + 3600,
        "iat" => now,
        "nonce" => "nonce",
        "email" => "user@example.com",
        "name" => "Test User",
        "preferred_username" => "testuser",
        "picture" => "https://sso.test/avatar.png"
      }
      |> Map.merge(Map.new(claim_overrides))

    assert {:ok, id_token} = Assent.JWTAdapter.AssentJWT.sign(claims, "HS256", "client_secret", json_library: Jason)
    id_token
  end
end
