defmodule PinchflatWeb.MediaItems.MediaItemController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias PinchflatWeb.Schemas

  tags(["Podcasts"])

  def show(conn, %{"id" => id}) do
    media_item =
      id
      |> Media.get_media_item!()
      |> Repo.preload([:source, tasks: [:job]])

    active_tab = tab_param(conn.params, ~w(media tasks), "media")
    watch = MediaWatch.get_watch_for_media_item(media_item.id)
    watch_events = (watch && MediaWatch.list_events(watch.id)) || []
    archive_summary = watch && OriginalArchive.summary(watch)

    render(conn, :show,
      media_item: media_item,
      watch: watch,
      watch_events: watch_events,
      archive_summary: archive_summary,
      archive_files: archive_files(watch, archive_summary),
      watch_policy_enabled: MediaWatch.effective_watch_window_days(Repo.preload(media_item.source, :media_profile)) > 0,
      active_tab: active_tab,
      tab_href: fn tab -> ~p"/sources/#{media_item.source_id}/media/#{media_item}?#{[tab: tab]}" end
    )
  end

  defp archive_files(%{archive_state: "published"}, {:ok, %{entries: entries}}), do: entries
  defp archive_files(_watch, _summary), do: []

  def edit(conn, %{"id" => id}) do
    media_item = Media.get_media_item!(id)
    changeset = Media.change_media_item(media_item)

    render(conn, :edit, media_item: media_item, changeset: changeset)
  end

  def update(conn, %{"id" => id, "media_item" => params}) do
    media_item = Media.get_media_item!(id)

    case Media.update_media_item(media_item, params) do
      {:ok, media_item} ->
        conn
        |> put_flash(:info, "Media Item updated successfully.")
        |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, media_item: media_item, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id} = params) do
    prevent_download = Map.get(params, "prevent_download", false)
    media_item = Media.get_media_item!(id)

    case Media.delete_media_files(media_item, %{prevent_download: prevent_download}) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Files deleted successfully.")
        |> redirect(to: ~p"/sources/#{media_item.source_id}")

      {:error, :watch_hold} ->
        conn
        |> put_flash(
          :error,
          "Watch protection prevents deletion of the current files. Review the saved original and watch protection settings before trying again."
        )
        |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      {:error, reason} ->
        Logger.warning("Media file deletion failed for item ##{media_item.id}: #{inspect(reason)}")

        conn
        |> put_flash(
          :error,
          "Some files could not be deleted. Check filesystem permissions and storage, then retry. The media record was kept."
        )
        |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
    end
  end

  def force_download(conn, %{"media_item_id" => id}) do
    media_item = Media.get_media_item!(id)

    :ok =
      case MediaDownloadWorker.kickoff_with_task(media_item, %{force: true, reset_last_error: true}) do
        {:ok, _} -> :ok
        {:error, :duplicate_job} -> :ok
        err -> err
      end

    conn
    |> put_flash(:info, "Download task enqueued.")
    |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
  end

  # See here for details on streaming files and range requests:
  # https://www.zeng.dev/post/2023-http-range-and-play-mp4-in-browser/
  #
  # Uses the UUID instead of the ID to avoid enumeration attacks
  # since streaming is a public endpoint (ie: no auth required)
  operation(:stream,
    operation_id: "MediaItems.MediaItemController.stream",
    summary: "Stream media file",
    description: """
    Streams a media file with HTTP Range request support for seeking.
    Supports partial content delivery (206) for efficient streaming.
    """,
    parameters: [
      uuid: [in: :path, description: "Media item UUID", schema: %Schema{type: :string, format: :uuid}, required: true],
      range: [
        in: :header,
        name: "Range",
        description: "Byte range for partial content (e.g., 'bytes=0-1023')",
        schema: %Schema{type: :string, example: "bytes=0-1023"}
      ]
    ],
    responses: [
      ok: {
        "Full media file",
        "video/*",
        %Schema{type: :string, format: :binary, description: "Media file data"}
      },
      partial_content: {
        "Partial content (for range requests)",
        "video/*",
        %Schema{type: :string, format: :binary, description: "Partial media file data"}
      },
      not_found: {"Media file not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def stream(conn, %{"uuid" => uuid}) do
    media_item = Repo.get_by!(MediaItem, uuid: uuid)
    serve_file(conn, media_item.media_filepath, media_item.title)
  end

  @doc false
  def serve_file(conn, path, filename) do
    if is_binary(path) and File.regular?(path) do
      file_size = File.stat!(path).size
      mime_type = MIME.from_path(path)

      case parse_range(conn, file_size) do
        {:ok, {start_pos, end_pos}} ->
          length = end_pos - start_pos + 1

          conn
          |> put_resp_content_type(mime_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{file_size}")
          |> put_resp_header("content-length", to_string(length))
          |> put_resp_header(
            "content-disposition",
            "inline; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)}"
          )
          |> send_file(206, path, start_pos, length)

        {:error, :invalid_range} ->
          conn
          |> put_resp_content_type(mime_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-length", to_string(file_size))
          |> put_resp_header(
            "content-disposition",
            "inline; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)}"
          )
          |> send_file(200, path)

        {:error, :unsatisfiable_range} ->
          conn
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-range", "bytes */#{file_size}")
          |> send_resp(416, "")
      end
    else
      send_resp(conn, 404, "File not found")
    end
  end

  defp parse_range(conn, file_size) do
    # We do not advertise validators, so an If-Range request must receive the full file.
    with "GET" <- conn.method,
         [] <- get_req_header(conn, "if-range"),
         [range_header] <- get_req_header(conn, "range"),
         [start_pos, end_pos] <- Regex.run(~r/^bytes=([0-9]*)-([0-9]*)$/, range_header, capture: :all_but_first) do
      validate_range(start_pos, end_pos, file_size)
    else
      _ -> {:error, :invalid_range}
    end
  end

  defp validate_range(start_pos, end_pos, file_size) do
    case {start_pos, end_pos} do
      {"", ""} ->
        {:error, :invalid_range}

      {"", suffix} ->
        suffix_range(String.to_integer(suffix), file_size)

      {start, ""} ->
        start = String.to_integer(start)
        byte_range(start, max(start, file_size - 1), file_size)

      {start, last} ->
        byte_range(String.to_integer(start), String.to_integer(last), file_size)
    end
  end

  defp suffix_range(suffix, file_size) when suffix == 0 or file_size == 0,
    do: {:error, :unsatisfiable_range}

  defp suffix_range(suffix, file_size), do: {:ok, {max(file_size - suffix, 0), file_size - 1}}

  defp byte_range(start, last, _file_size) when last < start, do: {:error, :invalid_range}
  defp byte_range(start, _last, file_size) when start >= file_size, do: {:error, :unsatisfiable_range}
  defp byte_range(start, last, file_size), do: {:ok, {start, min(last, file_size - 1)}}

  defp tab_param(params, allowed_tabs, default_tab) do
    tab = params["tab"]

    if tab in allowed_tabs do
      tab
    else
      default_tab
    end
  end
end
