defmodule PinchflatWeb.Plugs do
  @moduledoc """
  Custom plugs for PinchflatWeb.
  """

  use PinchflatWeb, :router
  alias Pinchflat.Settings

  @doc """
  If the `expose_feed_endpoints` setting is true, this plug does nothing. Otherwise, it calls `basic_auth/2`.
  """
  def maybe_basic_auth(conn, opts) do
    if Application.get_env(:pinchflat, :expose_feed_endpoints) do
      conn
    else
      basic_auth(conn, opts)
    end
  end

  @doc """
  If the `basic_auth_username` and `basic_auth_password` settings are set, this plug calls `Plug.BasicAuth.basic_auth/3`.
  """
  def basic_auth(conn, _opts) do
    username = Application.get_env(:pinchflat, :basic_auth_username)
    password = Application.get_env(:pinchflat, :basic_auth_password)

    if credential_set?(username) && credential_set?(password) do
      Plug.BasicAuth.basic_auth(conn, username: username, password: password, realm: "Pinchflat")
    else
      conn
    end
  end

  @doc """
  Basic auth for browser UI routes. No-op when OIDC SSO is enabled, since
  those routes are gated by `require_sso_auth/2` instead. Feed routes keep
  using `basic_auth/2` (via `maybe_basic_auth/2`) so podcast clients retain
  Basic Auth under SSO.
  """
  def browser_basic_auth(conn, opts) do
    if PinchflatWeb.OIDC.enabled?() do
      conn
    else
      basic_auth(conn, opts)
    end
  end

  @doc """
  Requires an SSO session when OIDC is configured; no-op otherwise.

  Redirects unauthenticated browser requests to the login page, preserving
  the original path so the flow can return there after signing in. Must run
  AFTER `fetch_session` in the pipeline.
  """
  def require_sso_auth(conn, _opts) do
    if PinchflatWeb.OIDC.enabled?() do
      case get_session(conn, PinchflatWeb.OIDC.session_key()) do
        nil ->
          redirect_to = conn.request_path <> query_string(conn)

          conn
          |> Phoenix.Controller.redirect(to: "/auth/login?" <> URI.encode_query(redirect_to: redirect_to))
          |> halt()

        user ->
          assign(conn, :sso_user, user)
      end
    else
      conn
    end
  end

  defp query_string(%{query_string: ""}), do: ""
  defp query_string(%{query_string: qs}), do: "?" <> qs

  @doc """
  Removes the `x-frame-options` header from the response to allow the page to be embedded in an iframe.
  """
  def allow_iframe_embed(conn, _opts) do
    delete_resp_header(conn, "x-frame-options")
  end

  @doc """
  If the `route_token` query parameter matches the `route_token` setting, this plug does nothing.
  Otherwise, it sends a 401 response.
  """
  def token_protected_route(%{query_params: %{"route_token" => route_token}} = conn, _opts) do
    if Settings.get!(:route_token) == route_token do
      conn
    else
      send_unauthorized(conn)
    end
  end

  def token_protected_route(conn, _opts) do
    send_unauthorized(conn)
  end

  defp credential_set?(credential) do
    credential && credential != ""
  end

  defp send_unauthorized(conn) do
    conn
    |> send_resp(:unauthorized, "Unauthorized")
    |> halt()
  end
end
