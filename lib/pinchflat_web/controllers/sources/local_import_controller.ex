defmodule PinchflatWeb.Sources.LocalImportController do
  use PinchflatWeb, :controller

  alias Pinchflat.Media.LocalImport
  alias Pinchflat.Sources

  def new(conn, %{"id" => id}) do
    render_page(conn, id, "", nil, nil)
  end

  def preview(conn, %{"id" => id, "import" => %{"directory" => directory}}) do
    case LocalImport.preview(id, directory) do
      {:ok, preview} ->
        token = Phoenix.Token.sign(conn, "local-import", {id, directory, preview.fingerprint})
        render_page(conn, id, directory, Map.put(preview, :token, token), nil)

      {:error, reason} ->
        render_page(conn, id, directory, nil, error_message(reason))
    end
  end

  def preview(conn, %{"id" => id}), do: render_page(conn, id, "", nil, "Enter a folder relative to downloads.")

  def apply(conn, %{"id" => id, "token" => token}) do
    with {:ok, {^id, directory, fingerprint}} <- Phoenix.Token.verify(conn, "local-import", token, max_age: 900),
         {:ok, %{imported: imported}} <- LocalImport.apply_preview(id, directory, fingerprint) do
      conn
      |> put_flash(:info, "Imported #{imported} existing media item(s). Your files were not moved or downloaded.")
      |> redirect(to: ~p"/sources/#{id}")
    else
      {:error, reason} -> render_page(conn, id, "", nil, error_message(reason))
      _ -> render_page(conn, id, "", nil, "Preview expired or does not match this source. Scan the folder again.")
    end
  end

  def apply(conn, %{"id" => id}), do: render_page(conn, id, "", nil, "Scan the folder before importing.")

  defp render_page(conn, id, directory, preview, error) do
    conn
    |> put_view(html: PinchflatWeb.Sources.SourceHTML)
    |> render(:import_downloads, source: Sources.get_source!(id), directory: directory, preview: preview, error: error)
  end

  defp error_message(:pause_source_first), do: "Pause this source before scanning or importing existing downloads."
  defp error_message(:source_jobs_running), do: "Wait for this source's running jobs to finish, then scan again."
  defp error_message(:stale_preview), do: "The files or source changed since this preview. Scan again before importing."
  defp error_message(:too_many_files), do: "This scan is limited to 5,000 files. Choose a smaller folder."
  defp error_message(:outside_downloads), do: "Choose a folder inside the configured downloads directory."
  defp error_message(_reason), do: "The import could not be applied. Check the folder and metadata, then scan again."
end
