defmodule PinchflatWeb.Browse.ScopedBrowseLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Settings.YtDlpConfigFile
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Sources.Source
  alias PinchflatWeb.Browse.BrowseLive

  setup :set_mox_global

  setup do
    original_extras = Application.get_env(:pinchflat, :extras_directory)
    extras = Path.join(System.tmp_dir!(), "scoped-browse-#{System.unique_integer([:positive])}")
    File.mkdir_p!(extras)
    Application.put_env(:pinchflat, :extras_directory, extras)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original_extras)
      File.rm_rf!(extras)
    end)

    :ok
  end

  test "W03: video detail download uses the item-scoped editor value", %{conn: conn} do
    profile = media_profile_fixture()
    video_id = "vid_test_123"

    source =
      source_fixture(%{
        collection_type: :video,
        source_type: :video,
        collection_id: video_id,
        original_url: "https://www.youtube.com/watch?v=#{video_id}",
        media_profile_id: profile.id
      })

    item = media_item_fixture(%{source_id: source.id, media_id: video_id, media_filepath: nil})
    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "--existing\n", :missing)
    assert {:ok, %{version: version}} = YtDlpConfigFile.read_scope(:media_item, item.id)

    detail = %{
      id: video_id,
      url: "https://www.youtube.com/watch?v=#{video_id}",
      title: "Scoped detail video",
      description: "Detail description",
      channel_id: "UC_scoped",
      channel_title: "Scoped Channel",
      duration: 360,
      upload_date: "20261001",
      thumbnails: [%{"url" => "https://example.com/detail.jpg", "width" => 640}],
      thumbnail: "https://example.com/detail.jpg",
      view_count: 100
    }

    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "scoped", _opts ->
      {:ok, [Map.put(detail, :thumbnail, "https://example.com/detail.jpg")]}
    end)

    Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn ^video_id, _opts ->
      {:ok, detail}
    end)

    {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
    render_change(view, "select_profile", %{profile_id: to_string(profile.id)})

    view
    |> form("#browse_search_form", %{"query" => "scoped"})
    |> render_submit()

    render_async(view)

    view
    |> element("button[phx-click='view_video_details'][phx-value-id='#{video_id}']")
    |> render_click()

    assert render_async(view) =~ "--existing"

    render_hook(view, "update_detail_options", %{
      "yt_dlp_options" => "--detail-save\n",
      "yt_dlp_options_version" => version
    })

    view
    |> element("button[phx-click='download_video'][phx-value-from-detail='true']")
    |> render_click()

    assert {:ok, %{contents: "--detail-save\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})
  end

  test "F10: stale detail save preserves the draft and newer item file, then retry succeeds", %{conn: conn} do
    profile = media_profile_fixture()
    video_id = "vid_stale_123"

    source =
      source_fixture(%{
        collection_type: :video,
        source_type: :video,
        collection_id: video_id,
        original_url: "https://www.youtube.com/watch?v=#{video_id}",
        media_profile_id: profile.id
      })

    item = media_item_fixture(%{source_id: source.id, media_id: video_id, media_filepath: nil})
    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "original\n", :missing)
    assert {:ok, %{version: old_version}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "newer\n", :any)

    detail = %{
      id: video_id,
      url: "https://www.youtube.com/watch?v=#{video_id}",
      title: "Scoped stale detail",
      description: "Detail description",
      channel_id: "UC_stale",
      channel_title: "Scoped Channel",
      duration: 360,
      upload_date: "20261001",
      thumbnails: [%{"url" => "https://example.com/stale.jpg", "width" => 640}],
      thumbnail: "https://example.com/stale.jpg",
      view_count: 100
    }

    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "stale", _opts ->
      {:ok, [detail]}
    end)

    Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn ^video_id, _opts ->
      {:ok, detail}
    end)

    {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
    render_change(view, "select_profile", %{profile_id: to_string(profile.id)})

    view |> form("#browse_search_form", %{"query" => "stale"}) |> render_submit()
    render_async(view)

    view
    |> element("button[phx-click='view_video_details'][phx-value-id='#{video_id}']")
    |> render_click()

    render_async(view)

    render_hook(view, "update_detail_options", %{
      "yt_dlp_options" => "--stale-draft\n",
      "yt_dlp_options_version" => old_version
    })

    view
    |> element("button[phx-click='download_video'][phx-value-from-detail='true']")
    |> render_click()

    assert render(view) =~ "--stale-draft"
    assert {:ok, %{contents: "newer\n", version: current_version}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert [] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})

    render_hook(view, "update_detail_options", %{
      "yt_dlp_options" => "--retry-draft\n",
      "yt_dlp_options_version" => current_version
    })

    view
    |> element("button[phx-click='download_video'][phx-value-from-detail='true']")
    |> render_click()

    assert {:ok, %{contents: "--retry-draft\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})
  end

  test "W04: channel subscription confirmation saves source options before indexing", %{conn: conn} do
    profile = media_profile_fixture()
    channel_id = "UC_scoped_subscribe"

    {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

    render_hook(view, "prompt_subscribe_channel", %{"id" => channel_id, "title" => "Scoped Channel"})
    render_hook(view, "update_subscribe_options", %{"yt_dlp_options" => "--channel-option\n"})
    render_hook(view, "confirm_subscribe_channel", %{"id" => channel_id, "title" => "Scoped Channel"})

    source = Repo.get_by!(Source, collection_id: channel_id, media_profile_id: profile.id)
    assert {:ok, %{contents: "--channel-option\n"}} = YtDlpConfigFile.read_scope(:source, source.id)
    assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
  end

  test "R12: cancelling the subscription dialog writes no source or options", %{conn: conn} do
    media_profile_fixture()
    channel_id = "UC_scoped_cancel"

    {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

    render_hook(view, "prompt_subscribe_channel", %{"id" => channel_id, "title" => "Scoped Channel"})
    render_hook(view, "update_subscribe_options", %{"yt_dlp_options" => "--draft-only\n"})
    render_hook(view, "cancel_subscribe_channel", %{})

    refute Repo.get_by(Source, collection_id: channel_id)
    assert Repo.aggregate(Source, :count, :id) == 0
  end
end
