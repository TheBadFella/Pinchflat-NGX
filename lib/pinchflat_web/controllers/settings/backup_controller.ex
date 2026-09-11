defmodule PinchflatWeb.Settings.BackupController do
  @moduledoc """
  Creates and serves PostgreSQL database backups from the authenticated UI.
  """

  use PinchflatWeb, :controller

  alias Pinchflat.Backups

  @doc """
  Creates a PostgreSQL backup and streams the completed dump to the browser.
  """
  def create(conn, _params) do
    case Backups.create_backup() do
      {:ok, %{path: path, filename: filename}} ->
        send_download(conn, {:file, path},
          filename: filename,
          content_type: "application/octet-stream"
        )

      {:error, :unavailable} ->
        unavailable(conn)

      {:error, :pg_dump_unavailable} ->
        failure(conn, "PostgreSQL backup tooling is not available in this image.")

      {:error, _reason} ->
        failure(conn, "The PostgreSQL backup could not be created. Check the application logs.")
    end
  end

  @doc """
  Streams a previously completed backup after validating its generated name
  and regular-file type.
  """
  def download(conn, %{"filename" => filename}) do
    case Backups.download_path(filename) do
      {:ok, path} ->
        send_download(conn, {:file, path},
          filename: filename,
          content_type: "application/octet-stream"
        )

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That PostgreSQL backup is no longer available.")
        |> redirect(to: ~p"/settings")
    end
  end

  defp unavailable(conn) do
    conn
    |> put_flash(:error, "PostgreSQL backups are unavailable when PinchYT uses SQLite.")
    |> redirect(to: ~p"/settings")
  end

  defp failure(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/settings")
  end
end
