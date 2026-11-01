defmodule PinchflatWeb.Sources.BulkCutoffController do
  use PinchflatWeb, :controller

  alias Pinchflat.Sources.BulkCutoff
  alias PinchflatWeb.Sources.SourceHTML

  def preview(conn, params) do
    ids = params["source_ids"]
    value = params["cutoff_date"]

    case BulkCutoff.preview(ids, value) do
      {:ok, preview} ->
        token = Phoenix.Token.sign(conn, "bulk-source-cutoff", {ids, value, preview.fingerprint})

        conn
        |> put_view(html: SourceHTML)
        |> render(:bulk_cutoff,
          preview: preview,
          token: token,
          return_to: SourceHTML.source_list_path(params["return_to"])
        )

      {:error, reason} ->
        reject_preview(conn, reason, params)
    end
  end

  def apply(conn, %{"token" => token} = params) when is_binary(token) do
    with {:ok, {ids, value, fingerprint}} <- Phoenix.Token.verify(conn, "bulk-source-cutoff", token, max_age: 900),
         {:ok, sources} <- BulkCutoff.apply_preview(ids, value, fingerprint) do
      noun = if length(sources) == 1, do: "source", else: "sources"

      conn
      |> put_flash(:info, "Download cutoff updated for #{length(sources)} selected #{noun}.")
      |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
    else
      {:error, reason} -> reject_preview(conn, reason, params)
      _ -> reject_preview(conn, :stale_preview, params)
    end
  end

  def apply(conn, params), do: reject_preview(conn, :stale_preview, params)

  defp reject_preview(conn, reason, params) do
    message =
      case reason do
        :invalid_cutoff ->
          "Enter a valid cutoff date in YYYY-MM-DD format, or leave it blank to remove the cutoff."

        :invalid_source ->
          "The cutoff conflicts with a selected source's indexing cutoff or settings. Review the sources and try again."

        :invalid_selection ->
          "Select between 1 and 100 available sources before previewing the cutoff."

        _ ->
          "The sources changed or the preview expired. Select the sources and preview the cutoff again."
      end

    conn |> put_flash(:error, message) |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
  end
end
