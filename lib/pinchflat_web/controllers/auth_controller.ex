defmodule PinchflatWeb.AuthController do
  @moduledoc """
  Handles the optional OIDC/OAuth2 single sign-on flow using assent's
  Authorization Code strategy with CSRF state, PKCE, and nonce protection.

  All actions are reachable whether or not SSO is enabled; `login/2` simply
  redirects home when the feature is off.
  """

  use PinchflatWeb, :controller

  require Logger

  alias PinchflatWeb.Endpoint
  alias PinchflatWeb.OIDC

  @login_error_path "/auth/login?error=1"

  @doc """
  Renders the SSO login page, or redirects home when SSO is disabled.
  """
  @spec login(Conn.t(), map()) :: Conn.t()
  def login(conn, _params) do
    if OIDC.enabled?() do
      conn
      |> assign(:error, present?(conn.params["error"]))
      |> assign(:provider_name, OIDC.provider_name())
      |> assign(:redirect_to, conn.params["redirect_to"] || "/")
      |> render(:login, layout: {Layouts, :login})
    else
      redirect(conn, to: "/")
    end
  end

  @doc """
  Starts the authorization code flow by redirecting to the provider's
  authorization endpoint, stashing assent's session params for the callback.
  """
  @spec request(Conn.t(), map()) :: Conn.t()
  def request(conn, _params) do
    if OIDC.enabled?() do
      return_to = sanitize_return_to(conn.params["redirect_to"])

      case OIDC.provider_config(callback_url(conn)) |> Assent.Strategy.OIDC.authorize_url() do
        {:ok, %{url: url, session_params: session_params}} ->
          conn
          |> put_session(:oidc_session_params, session_params)
          |> put_session(:oidc_return_to, return_to)
          |> redirect(external: url)

        {:error, error} ->
          log_oidc_error("authorize_url failed", error)
          redirect(conn, to: @login_error_path)
      end
    else
      redirect(conn, to: "/")
    end
  end

  @doc """
  Completes the authorization code flow: verifies state/nonce, exchanges the
  code for tokens, validates the ID token, and stores the normalized user in
  the (renewed) session.
  """
  @spec callback(Conn.t(), map()) :: Conn.t()
  def callback(conn, _params) do
    conn = fetch_query_params(conn)
    session_params = get_session(conn, :oidc_session_params)
    return_to = get_session(conn, :oidc_return_to) || "/"

    conn = conn |> delete_session(:oidc_session_params) |> delete_session(:oidc_return_to)

    case do_callback(conn, session_params) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(OIDC.session_key(), user)
        |> put_session(:live_socket_id, new_live_socket_id())
        |> redirect(to: return_to)

      {:error, error} ->
        log_oidc_error("callback failed", error)
        redirect(conn, to: @login_error_path)
    end
  end

  @doc """
  Clears the session, disconnects any live LiveView sockets, and returns
  the user to the login page.
  """
  @spec logout(Conn.t(), map()) :: Conn.t()
  def logout(conn, _params) do
    # LiveView tokens signed into already-rendered pages outlive the cookie
    # session, so explicitly kill any sockets started before logout.
    if live_socket_id = get_session(conn, :live_socket_id) do
      Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> redirect(to: ~p"/auth/login")
  end

  defp do_callback(conn, session_params) do
    with {:ok, session_params} <- valid_session_params(session_params),
         config <-
           conn
           |> callback_url()
           |> OIDC.provider_config()
           |> Keyword.put(:session_params, session_params),
         {:ok, %{user: user}} <- Assent.Strategy.OIDC.callback(config, conn.params) do
      {:ok, normalize_user(user)}
    end
  rescue
    # assent reports tampered/missing state via CallbackCSRFError and provider
    # error params via CallbackError; stale or partial session params surface
    # as KeyError from Map.fetch!/1 inside assent. All end at the login page.
    error in [Assent.CallbackCSRFError, Assent.CallbackError, KeyError] ->
      {:error, error}
  end

  defp valid_session_params(session_params) when is_map(session_params) and map_size(session_params) > 0,
    do: {:ok, session_params}

  defp valid_session_params(_session_params), do: {:error, :missing_session_params}

  defp callback_url(conn) do
    cfg = Application.get_env(:pinchflat, :oidc)

    if (cfg && is_binary(cfg[:redirect_uri])) and cfg[:redirect_uri] != "" do
      cfg[:redirect_uri]
    else
      url(conn, ~p"/auth/oidc/callback")
    end
  end

  # Only same-app paths are allowed; prevents open redirects via the
  # redirect_to param and the stored return_to session value. Backslashes
  # are rejected because browsers treat them as path separators, so
  # "/\evil.com" would resolve to the protocol-relative "//evil.com".
  defp sanitize_return_to(return_to) when is_binary(return_to) do
    if String.starts_with?(return_to, "/") and not String.starts_with?(return_to, "//") and
         not String.contains?(return_to, "\\") do
      return_to
    else
      "/"
    end
  end

  defp sanitize_return_to(_return_to), do: "/"

  defp normalize_user(user) do
    %{
      sub: user["sub"],
      email: user["email"],
      name: user["name"],
      preferred_username: user["preferred_username"],
      picture: user["picture"]
    }
  end

  defp new_live_socket_id, do: "sso_sessions:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # assent errors that embed an HTTP response can carry the request headers —
  # assent 0.3.1's Req adapter echoes them into the struct, including the
  # Basic auth header with the client secret — so they must never be fully
  # inspected or formatted into logs. Log the type and status only.
  defp log_oidc_error(prefix, %{response: %{status: status}} = error) do
    Logger.warning("OIDC #{prefix}: #{inspect(error.__struct__)} status=#{status} (details redacted)")
  end

  defp log_oidc_error(prefix, %KeyError{} = error) do
    Logger.warning("OIDC #{prefix}: #{inspect(error)}")
  end

  defp log_oidc_error(prefix, error) when is_exception(error) do
    Logger.warning("OIDC #{prefix}: #{Exception.message(error)}")
  end

  defp log_oidc_error(prefix, error) do
    Logger.warning("OIDC #{prefix}: #{inspect(error)}")
  end

  defp present?(value), do: value not in [nil, ""]
end
