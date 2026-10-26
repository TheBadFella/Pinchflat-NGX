defmodule PinchflatWeb.Settings.BackupController do
  @moduledoc """
  Creates and serves PostgreSQL database backups from the authenticated UI.
  """

  use PinchflatWeb, :controller

  alias Pinchflat.Backups
  alias Pinchflat.Settings

  def index(conn, _params) do
    render_index(conn, Settings.change_setting(Settings.record()))
  end

  def update(conn, %{"setting" => %{"postgres_backup_retention_count" => count}})
      when not is_nil(count) and count != "" do
    if Backups.available?() do
      case Settings.update_setting(Settings.record(), %{postgres_backup_retention_count: count}) do
        {:ok, _setting} ->
          conn |> put_flash(:info, "Backup retention updated.") |> redirect(to: ~p"/backups")

        {:error, changeset} ->
          conn |> put_status(:unprocessable_entity) |> render_index(changeset)
      end
    else
      unavailable(conn)
    end
  end

  def update(conn, _params) do
    conn |> put_flash(:error, "Enter a number of backups to keep between 1 and 100.") |> redirect(to: ~p"/backups")
  end

  defp render_index(conn, changeset),
    do: render(conn, :index, backup_status: Backups.status(), changeset: changeset)

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

      {:error, :busy} ->
        failure(conn, "A PostgreSQL backup is already running. Try again in a moment.")

      {:error, _reason} ->
        failure(conn, "The PostgreSQL backup could not be created. Check the application logs.")
    end
  end

  @doc """
  Streams a previously completed backup after validating its generated name
  and regular-file type.

  The download routes use a glob segment so Phoenix keeps the `.dump`
  extension instead of reading it as a response format.
  """
  def download(conn, %{"filename" => segments}) do
    raw = segments |> List.wrap() |> Enum.join("/")
    filename = if String.ends_with?(raw, ".dump"), do: raw, else: raw <> ".dump"

    case Backups.download_path(filename) do
      {:ok, path} ->
        send_download(conn, {:file, path},
          filename: filename,
          content_type: "application/octet-stream"
        )

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That PostgreSQL backup is no longer available.")
        |> redirect(to: ~p"/backups")
    end
  end

  defp unavailable(conn) do
    conn
    |> put_flash(:error, "PostgreSQL backups are unavailable when Pinchflat-ngx uses SQLite.")
    |> redirect(to: ~p"/backups")
  end

  defp failure(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/backups")
  end
end
