defmodule PinchflatWeb.Plugs.PostgresMigrationGate do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
    path = "/" <> Enum.join(conn.path_info, "/")

    if Pinchflat.Database.PostgresMigration.pending?() and
         path not in [
           "/postgres_migration",
           "/postgres_migration/start",
           "/postgres_migration/complete",
           "/healthcheck",
           "/auth/login",
           "/auth/oidc/request",
           "/auth/oidc/callback",
           "/auth/logout"
         ] do
      if String.starts_with?(path, "/api/") do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":"postgres_migration_pending"}))
        |> halt()
      else
        conn |> Phoenix.Controller.redirect(to: "/postgres_migration") |> halt()
      end
    else
      conn
    end
  end
end
