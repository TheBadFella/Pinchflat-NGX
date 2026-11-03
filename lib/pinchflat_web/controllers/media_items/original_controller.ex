defmodule PinchflatWeb.MediaItems.OriginalController do
  use PinchflatWeb, :controller

  alias Pinchflat.Media
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias PinchflatWeb.MediaItems.MediaItemController

  def file(conn, params) do
    {item, watch} = scoped_watch!(params)

    with true <- watch.archive_state == "published" and is_nil(watch.released_at),
         {:ok, path} <- OriginalArchive.file(watch, params["role"]) do
      conn = put_resp_header(conn, "cache-control", "private, no-store")
      filename = "#{item.title} - original#{Path.extname(path)}"

      if params["download"] == "true" do
        send_download(conn, {:file, path}, filename: filename)
      else
        MediaItemController.serve_file(conn, path, filename)
      end
    else
      _ -> send_resp(conn, 404, "Saved original unavailable")
    end
  end

  def confirm(conn, params) do
    {item, watch} = scoped_watch!(params)

    case MediaWatch.release_confirmation(watch) do
      {:ok, token} ->
        render(conn, :confirm, media_item: item, watch: watch, token: token)

      {:error, _} ->
        conn
        |> put_flash(:error, "Unable to end watch protection. Check the application logs for file recovery errors.")
        |> redirect(to: ~p"/sources/#{item.source_id}/media/#{item}")
    end
  end

  def release(conn, params) do
    {item, _watch} = scoped_watch!(params)

    message =
      case MediaWatch.release_watch(item, params["confirmation"]) do
        {:ok, _} ->
          {:info,
           "Watch protection ended. The saved original was deleted. Your current files and manual protection settings are unchanged."}

        {:error, {:original_deletion_pending, _}} ->
          {:error,
           "Watch protection ended. Saved original cleanup is pending. Replacement and file deletion remain blocked until cleanup completes."}

        {:error, _} ->
          {:error, "The confirmation has expired or the watch status has changed. Review the details and try again."}
      end

    {kind, text} = message
    conn |> put_flash(kind, text) |> redirect(to: ~p"/sources/#{item.source_id}/media/#{item}")
  end

  defp scoped_watch!(%{"source_id" => source_id, "media_item_id" => id}) do
    item = Media.get_media_item!(id)
    watch = MediaWatch.get_watch_for_media_item(item.id)

    if to_string(item.source_id) != source_id or is_nil(watch),
      do: raise(Ecto.NoResultsError, queryable: Pinchflat.Media.MediaItem)

    {item, watch}
  end
end
