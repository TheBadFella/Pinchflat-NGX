defmodule PinchflatWeb.Podcasts.PodcastController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use Pinchflat.Media.MediaQuery

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Podcasts.RssFeedBuilder
  alias Pinchflat.Podcasts.OpmlFeedBuilder
  alias Pinchflat.Podcasts.PodcastHelpers
  alias PinchflatWeb.Schemas

  tags(["Podcasts"])

  operation(:opml_feed,
    operation_id: "Podcasts.PodcastController.opml_feed",
    summary: "OPML feed",
    description:
      "Returns an OPML feed containing all sources as podcast feeds. Useful for importing into podcast clients.",
    responses: [
      ok: {
        "OPML XML feed",
        "application/opml+xml",
        %Schema{type: :string, description: "OPML XML document"}
      }
    ]
  )

  def opml_feed(conn, _params) do
    url_base = Phoenix.VerifiedRoutes.unverified_url(conn, "")
    xml = OpmlFeedBuilder.build(url_base, PodcastHelpers.opml_sources())

    conn
    |> put_resp_content_type("application/opml+xml")
    |> put_resp_header("content-disposition", "inline")
    |> send_resp(200, xml)
  end

  operation(:rss_feed,
    operation_id: "Podcasts.PodcastController.rss_feed",
    summary: "RSS feed for source",
    description: "Returns an RSS podcast feed for a specific source. Contains up to 2000 most recent media items.",
    parameters: [
      uuid: [in: :path, description: "Source UUID", schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok: {
        "RSS XML feed",
        "application/rss+xml",
        %Schema{type: :string, description: "RSS XML document"}
      },
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def rss_feed(conn, %{"uuid" => uuid}) do
    source = Repo.get_by!(Source, uuid: uuid)
    url_base = Phoenix.VerifiedRoutes.unverified_url(conn, "")
    xml = RssFeedBuilder.build(source, limit: 2_000, url_base: url_base)

    conn
    |> put_resp_content_type("application/rss+xml")
    |> put_resp_header("content-disposition", "inline")
    |> send_resp(200, xml)
  end

  operation(:feed_image,
    operation_id: "Podcasts.PodcastController.feed_image",
    summary: "Source feed image",
    description: "Returns the cover image for a source's podcast feed",
    parameters: [
      uuid: [in: :path, description: "Source UUID", schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok: {
        "Image file",
        "image/*",
        %Schema{type: :string, format: :binary, description: "Image file data"}
      },
      not_found: {"Image not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def feed_image(conn, %{"uuid" => uuid}) do
    source = Repo.get_by!(Source, uuid: uuid)

    # This is used to fetch a fallback cover image
    # if the source doesn't have any usable images
    media_items =
      MediaQuery.new()
      |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
      |> Repo.maybe_limit(1)
      |> Repo.all()

    case PodcastHelpers.select_cover_image(source, media_items) do
      {:error, _} ->
        send_resp(conn, 404, "Image not found")

      {:ok, filepath} ->
        conn
        |> put_resp_content_type(MIME.from_path(filepath))
        |> send_file(200, filepath)
    end
  end

  operation(:episode_image,
    operation_id: "Podcasts.PodcastController.episode_image",
    summary: "Episode thumbnail",
    description: "Returns the thumbnail image for a specific media item",
    parameters: [
      uuid: [in: :path, description: "Media item UUID", schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok: {
        "Image file",
        "image/*",
        %Schema{type: :string, format: :binary, description: "Image file data"}
      },
      not_found: {"Image not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def episode_image(conn, %{"uuid" => uuid}) do
    media_item = Repo.get_by!(MediaItem, uuid: uuid)

    if media_item.thumbnail_filepath && File.exists?(media_item.thumbnail_filepath) do
      conn
      |> put_resp_content_type(MIME.from_path(media_item.thumbnail_filepath))
      |> send_file(200, media_item.thumbnail_filepath)
    else
      send_resp(conn, 404, "Image not found")
    end
  end
end
