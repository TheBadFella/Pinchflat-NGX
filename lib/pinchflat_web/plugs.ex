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
  Requires the existing Basic Auth credentials for management API requests when
  browser authentication is configured. OIDC sessions do not authorize API writes.
  Returns the connection, or a halted 401 response.
  """
  def management_api_auth(conn, opts) do
    username = Application.get_env(:pinchflat, :basic_auth_username)
    password = Application.get_env(:pinchflat, :basic_auth_password)

    cond do
      credential_set?(username) && credential_set?(password) ->
        case get_req_header(conn, "authorization") do
          [_header] -> basic_auth(conn, opts)
          _ -> api_unauthorized(conn)
        end

      PinchflatWeb.OIDC.enabled?() || credential_set?(username) || credential_set?(password) ->
        api_unauthorized(conn)

      true ->
        conn
    end
  end

  defp api_unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Pinchflat"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "API access requires configured Basic Auth credentials."}))
    |> halt()
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
  Applies the configured dashboard embedding policy while preserving other CSP directives.
  """
  def allow_iframe_embed(conn, _opts) do
    origins = Application.get_env(:pinchflat, :iframe_allowed_origins, [])

    cond do
      not Application.get_env(:pinchflat, :allow_iframe_embed, true) ->
        conn
        |> put_resp_header("x-frame-options", "SAMEORIGIN")
        |> frame_ancestors("'self'")

      origins != [] ->
        conn
        |> delete_resp_header("x-frame-options")
        |> frame_ancestors(Enum.join(["'self'" | origins], " "))

      true ->
        delete_resp_header(conn, "x-frame-options")
    end
  end

  defp frame_ancestors(conn, origins) do
    directives =
      conn
      |> get_resp_header("content-security-policy")
      |> Enum.flat_map(&String.split(&1, ";", trim: true))
      |> Enum.reject(&(String.trim(&1) |> String.starts_with?("frame-ancestors ")))

    put_resp_header(conn, "content-security-policy", Enum.join(directives ++ ["frame-ancestors #{origins}"], "; "))
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

  @doc """
  Ensures that when legacy migration review is pending, browser requests are directed
  to the migration review screen until the user confirms the review.
  """
  def require_migration_review(conn, _opts) do
    if Pinchflat.LegacyMigration.legacy_migration_pending?() do
      case conn.request_path do
        "/" ->
          conn

        "/migration/confirm_review" ->
          conn

        "/migration/rescan" ->
          conn

        _ ->
          conn
          |> Phoenix.Controller.redirect(to: "/")
          |> Plug.Conn.halt()
      end
    else
      conn
    end
  end

  @doc """
  Keeps API writes held during legacy or PostgreSQL migration review while allowing read-only requests.
  """
  def hold_migration_api_writes(conn, _opts) do
    if conn.method not in ["GET", "HEAD", "OPTIONS"] &&
         (Pinchflat.LegacyMigration.legacy_migration_pending?() or Pinchflat.Database.PostgresMigration.pending?()) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(423, Jason.encode!(%{error: "Complete migration review before changing the library."}))
      |> Plug.Conn.halt()
    else
      conn
    end
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
