defmodule PinchflatWeb.LiveAuth do
  @moduledoc """
  Requires an SSO session for LiveView mounts when OIDC is enabled.

  The `/live` socket is mounted in the endpoint, outside the router pipelines,
  so `require_sso_auth/2` never sees socket connections.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    if PinchflatWeb.OIDC.enabled?() and
         is_nil(session[to_string(PinchflatWeb.OIDC.session_key())]) do
      {:halt, redirect(socket, to: "/auth/login")}
    else
      {:cont, socket}
    end
  end
end
