defmodule PinchflatWeb.PostgresMigrationController do
  use PinchflatWeb, :controller
  alias Pinchflat.Database.PostgresMigration, as: Migration

  def show(conn, _params),
    do:
      render(conn, :show, record: Migration.record(), queues: Migration.queues(), processing_held: Migration.pending?())

  def start(conn, %{"stopped" => "true", "backup" => "true"}) do
    case Migration.kickoff() do
      :ok ->
        redirect(conn, to: ~p"/postgres_migration")

      _ ->
        conn
        |> put_flash(:error, "Migration is not ready to start. Refresh this page and check its status.")
        |> redirect(to: ~p"/postgres_migration")
    end
  end

  def start(conn, _params),
    do:
      conn
      |> put_flash(:error, "Stop the old instance and back up config and downloads before continuing.")
      |> redirect(to: ~p"/postgres_migration")

  def complete(conn, params) do
    pauses = Map.get(params, "paused_queues", [])

    case Migration.complete(pauses) do
      :ok ->
        conn
        |> put_flash(
          :info,
          "Migration confirmed. Restart the container to apply your queue choices and resume normal processing."
        )
        |> redirect(to: ~p"/postgres_migration")

      {:error, :database_write_failed} ->
        conn
        |> put_flash(
          :error,
          "Could not save your queue choices. Background work remains held. Check the database connection and retry."
        )
        |> redirect(to: ~p"/postgres_migration")

      _ ->
        conn |> put_flash(:error, "The migration cannot be confirmed yet.") |> redirect(to: ~p"/postgres_migration")
    end
  end
end
