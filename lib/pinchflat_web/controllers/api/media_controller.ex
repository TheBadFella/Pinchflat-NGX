defmodule PinchflatWeb.Api.MediaController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ecto.Query, warn: false

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias PinchflatWeb.Schemas

  @default_limit 50
  @min_limit 1
  @max_limit 500

  tags(["Media"])

  operation(:index,
    operation_id: "Api.MediaController.index",
    summary: "List media items",
    description: "Returns a list of media items with optional filtering",
    parameters: [
      source_id: [in: :query, description: "Filter by source ID", schema: %Schema{type: :integer}],
      limit: [
        in: :query,
        description: "Maximum number of results to return (1-500)",
        schema: %Schema{type: :integer, minimum: 1, maximum: 500, default: 50}
      ]
    ],
    responses: [
      ok: {"List of media items", "application/json", Schemas.MediaItemsListResponse}
    ]
  )

  def index(conn, params) do
    limit =
      params
      |> Map.get("limit", "#{@default_limit}")
      |> parse_int(@default_limit)
      |> clamp(@min_limit, @max_limit)

    query = from(mi in MediaItem, order_by: [desc: mi.inserted_at], limit: ^limit)

    query =
      if source_id = params["source_id"] do
        from(mi in query, where: mi.source_id == ^source_id)
      else
        query
      end

    media_items =
      query
      |> Repo.all()
      |> Media.preload_api_assocs()

    conn
    |> put_status(:ok)
    |> json(%{data: media_items})
  end

  operation(:show,
    operation_id: "Api.MediaController.show",
    summary: "Get media item",
    description: "Returns details for a specific media item",
    parameters: [
      id: [in: :path, description: "Media item ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Media item details", "application/json", Schemas.MediaItem},
      not_found: {"Media item not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    media_item =
      id
      |> Media.get_media_item!()
      |> Media.preload_api_assocs()

    conn
    |> put_status(:ok)
    |> json(media_item)
  end

  operation(:delete,
    operation_id: "Api.MediaController.delete",
    summary: "Delete media item files",
    description: "Deletes the media files associated with a media item",
    parameters: [
      id: [in: :path, description: "Media item ID", schema: %Schema{type: :integer}, required: true],
      prevent_download: [
        in: :query,
        description: "Prevent future re-download of this media item",
        schema: %Schema{type: :boolean, default: false}
      ]
    ],
    responses: [
      ok: {"Media files deleted successfully", "application/json", Schemas.ActionResponse},
      not_found: {"Media item not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def delete(conn, %{"id" => id} = params) do
    media_item = Media.get_media_item!(id)
    prevent_download = params["prevent_download"] == "true" || params["prevent_download"] == true

    {:ok, _} = Media.delete_media_files(media_item, %{prevent_download: prevent_download})

    conn
    |> put_status(:ok)
    |> json(%{message: "Media files deleted successfully"})
  end

  operation(:download,
    operation_id: "Api.MediaController.download",
    summary: "Force download media item",
    description: "Triggers a download job for the specified media item",
    parameters: [
      id: [in: :path, description: "Media item ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Download job created", "application/json", Schemas.ActionResponse},
      not_found: {"Media item not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def download(conn, %{"id" => id}) do
    media_item = Media.get_media_item!(id) |> Repo.preload(:source)

    case MediaDownloadWorker.kickoff_with_task(media_item, %{force: true}) do
      {:ok, _} -> :ok
      {:error, :duplicate_job} -> :ok
      err -> err
    end

    conn
    |> put_status(:ok)
    |> json(%{message: "Download job created"})
  end

  operation(:recent_downloads,
    operation_id: "Api.MediaController.recent_downloads",
    summary: "Recent downloads",
    description: "Returns a list of recently downloaded media items",
    parameters: [
      limit: [
        in: :query,
        description: "Maximum number of results to return (1-500)",
        schema: %Schema{type: :integer, minimum: 1, maximum: 500, default: 50}
      ]
    ],
    responses: [
      ok: {"List of recently downloaded media items", "application/json", Schemas.RecentDownloadsResponse}
    ]
  )

  def recent_downloads(conn, params) do
    limit =
      params
      |> Map.get("limit", "#{@default_limit}")
      |> parse_int(@default_limit)
      |> clamp(@min_limit, @max_limit)

    media_items =
      from(mi in MediaItem,
        where: not is_nil(mi.media_downloaded_at),
        order_by: [desc: mi.media_downloaded_at],
        limit: ^limit,
        select: %{
          id: mi.id,
          uuid: mi.uuid,
          title: mi.title,
          media_id: mi.media_id,
          source_id: mi.source_id,
          uploaded_at: mi.uploaded_at,
          media_downloaded_at: mi.media_downloaded_at,
          media_filepath: mi.media_filepath,
          thumbnail_filepath: mi.thumbnail_filepath,
          metadata_filepath: mi.metadata_filepath,
          nfo_filepath: mi.nfo_filepath,
          subtitle_filepaths: mi.subtitle_filepaths
        }
      )
      |> Repo.all()

    conn
    |> put_status(:ok)
    |> json(%{data: media_items})
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp clamp(value, min_val, max_val) do
    value
    |> Kernel.max(min_val)
    |> Kernel.min(max_val)
  end
end
