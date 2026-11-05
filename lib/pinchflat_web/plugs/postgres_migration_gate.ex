defmodule PinchflatWeb.Plugs.PostgresMigrationGate do
  @moduledoc """
  Redirects ordinary browser navigation to the PostgreSQL migration review while a
  transfer is pending. It runs after browser authentication and before the legacy
  migration review so a pending PostgreSQL transfer cannot be bypassed by creating
  a target library first.
  """

  import Plug.Conn

  @allowed_paths [
    "/postgres_migration",
    "/postgres_migration/start",
    "/postgres_migration/complete"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    if Pinchflat.Database.PostgresMigration.pending?() and conn.request_path not in @allowed_paths do
      conn
      |> Phoenix.Controller.redirect(to: "/postgres_migration")
      |> halt()
    else
      conn
    end
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) and Pinchflat.Database.PostgresMigration.pending?() do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/postgres_migration")}
    else
      {:cont, socket}
    end
  end
end
