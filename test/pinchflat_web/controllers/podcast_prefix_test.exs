defmodule PinchflatWeb.PodcastPrefixTest do
  use PinchflatWeb.ConnCase, async: false

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  setup do
    endpoint = PinchflatWeb.Endpoint
    original = Application.fetch_env!(:pinchflat, endpoint)
    prefixed = Keyword.update!(original, :url, &Keyword.put(&1, :path, "/pinchflat"))
    endpoint.config_change([{endpoint, prefixed}], [])
    on_exit(fn -> endpoint.config_change([{endpoint, original}], []) end)
    :ok
  end

  test "RSS self, media and artwork URLs contain the deployment prefix once", %{conn: conn} do
    source = source_fixture()
    media = media_item_with_attachments(%{source_id: source.id})
    conn = get(conn, "/sources/#{source.uuid}/feed.xml")
    body = response(conn, 200)
    base = "http://www.example.com/pinchflat"

    assert body =~ "#{base}/sources/#{source.uuid}/feed.xml"
    assert body =~ "#{base}/media/#{media.uuid}/stream#{Path.extname(media.media_filepath)}"
    assert body =~ "#{base}/media/#{media.uuid}/episode_image"
    refute body =~ "/pinchflat/pinchflat/"
  end

  test "OPML subscription URLs contain the deployment prefix once", %{conn: conn} do
    source = source_fixture()
    token = Pinchflat.Settings.get!(:route_token)
    conn = get(conn, "/sources/opml.xml", route_token: token)
    body = response(conn, 200)

    assert body =~ "http://www.example.com/pinchflat/sources/#{source.uuid}/feed.xml"
    refute body =~ "/pinchflat/pinchflat/"
  end
end
