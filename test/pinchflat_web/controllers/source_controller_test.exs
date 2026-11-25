defmodule PinchflatWeb.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.CustomPoster
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Tasks

  test "list actions return to Individual videos and reject other return destinations", %{conn: conn} do
    source = source_fixture(collection_type: :video)
    params = %{"source_ids" => [to_string(source.id)], "return_to" => "/sources?type=videos"}
    assert redirected_to(post(conn, ~p"/sources/pause_selected", params)) == "/sources?type=videos"
    assert redirected_to(post(conn, ~p"/sources/resume_selected", params)) == "/sources?type=videos"
    assert redirected_to(post(conn, ~p"/sources/assign_profile_selected", params)) == "/sources?type=videos"

    params = Map.put(params, "return_to", "https://example.com")
    assert redirected_to(post(conn, ~p"/sources/pause_selected", params)) == "/sources"
  end

  test "cutoff preview and confirmation retain the Individual videos tab", %{conn: conn} do
    source = source_fixture(collection_type: :video)
    params = %{"source_ids" => [to_string(source.id)], "cutoff_date" => "", "return_to" => "/sources?type=videos"}
    response = post(conn, ~p"/sources/cutoff/preview", params)
    html = html_response(response, 200)
    assert html =~ ~s(href="/sources?type=videos")
    assert html =~ ~s(name="return_to" value="/sources?type=videos")

    assert redirected_to(
             post(conn, ~p"/sources/cutoff/apply", %{
               "token" => response.assigns.token,
               "return_to" => "/sources?type=videos"
             })
           ) == "/sources?type=videos"

    assert redirected_to(post(conn, ~p"/sources/cutoff/preview", %{"return_to" => "/sources?type=videos"})) ==
             "/sources?type=videos"
  end

  test "Sources tabs have direct URLs and filter the existing source list", %{conn: conn} do
    source_fixture(custom_name: "Channel entry")
    source_fixture(custom_name: "Individual entry", collection_type: :video)

    html = conn |> get(~p"/sources") |> html_response(200)
    assert html =~ "Channels &amp; Playlists"
    assert html =~ "Individual Videos"
    assert html =~ "Channel entry"
    refute html =~ "Individual entry"

    html = conn |> get(~p"/sources?type=videos") |> html_response(200)
    assert html =~ "Individual entry"
    refute html =~ "Channel entry"
    assert html =~ ~s(href="/sources?type=videos")

    html = conn |> get(~p"/sources?type=unknown") |> html_response(200)
    assert html =~ "Channel entry"
    refute html =~ "Individual entry"
  end

  setup do
    media_profile = media_profile_fixture()
    Settings.set(onboarding: false)

    extras_directory =
      Path.join(System.tmp_dir!(), "pinchflat-source-controller-cookie-tests-#{System.unique_integer([:positive])}")

    original_directory = Application.get_env(:pinchflat, :extras_directory)

    Application.put_env(:pinchflat, :extras_directory, extras_directory)
    File.mkdir_p!(extras_directory)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original_directory)
      File.rm_rf!(extras_directory)
    end)

    {:ok,
     %{
       create_attrs: %{
         media_profile_id: media_profile.id,
         collection_type: "channel",
         original_url: "https://www.youtube.com/@pinchflattest"
       },
       update_attrs: %{
         original_url: "https://www.youtube.com/playlist?list=PL1234567890ABCDEF"
       },
       invalid_attrs: %{original_url: nil, media_profile_id: nil},
       extras_directory: extras_directory
     }}
  end

  test "source retention preview names the inherited policy without copying its value", %{conn: conn} do
    profile = media_profile_fixture(%{retention_period_days: 30})
    source = source_fixture(media_profile_id: profile.id, retention_period_days: nil)

    html = conn |> get(~p"/sources/#{source.id}/edit") |> html_response(200)
    preview = html |> LazyHTML.from_document() |> LazyHTML.query("#source-retention-effective") |> LazyHTML.text()

    assert preview =~ "30 days (profile default)"
    assert html =~ "Retention override (days)"
    assert Repo.get!(Pinchflat.Sources.Source, source.id).retention_period_days == nil

    {:ok, _} = Pinchflat.Profiles.update_media_profile(profile, %{retention_period_days: 7})
    overview = conn |> get(~p"/sources/#{source.id}?#{[tab: "source"]}") |> html_response(200)
    assert overview =~ "7 days (profile default)"
  end

  test "JSON source reports raw and effective retention after profile changes", %{conn: conn} do
    profile = media_profile_fixture(%{retention_period_days: 3})
    source = source_fixture(media_profile_id: profile.id, retention_period_days: nil)
    url = ~p"/sources/#{source.id}"
    conn = put_req_header(conn, "accept", "application/json")

    body = conn |> get(url) |> json_response(200)
    assert body["retention_period_days"] == nil
    assert body["effective_retention_period_days"] == 3
    assert body["media_profile"]["retention_period_days"] == 3

    {:ok, _} = Pinchflat.Profiles.update_media_profile(profile, %{retention_period_days: 5})
    updated = conn |> get(url) |> json_response(200)
    assert updated["effective_retention_period_days"] == 5
  end

  test "source with only cutoff-skipped media renders instead of returning 500", %{conn: conn} do
    source = source_fixture(download_cutoff_date: ~D[2025-11-22])
    media_item_fixture(source_id: source.id, uploaded_at: ~U[2025-11-21 23:59:59Z], media_filepath: nil)

    html = conn |> get(~p"/sources/#{source}") |> html_response(200)
    assert html =~ "Every indexed item was published before this source&#39;s download cutoff date"
  end

  describe "index" do
    # Most of the tests are in `index_table_list_test.exs`
    test "returns 200", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert html_response(conn, 200) =~ "Sources"
    end

    test "links Quick Download to the Paste URL dialog", %{conn: conn} do
      html = conn |> get(~p"/sources") |> html_response(200)
      assert html =~ ~s(id="sources-quick-download")
      assert html =~ "Quick Download"
      assert html =~ ~s(href="/browse?paste=1")
    end

    test "returns 200 when a source has stored metadata", %{conn: conn} do
      source_with_metadata(%{custom_name: "Indexed Source"})

      conn = get(conn, ~p"/sources")
      assert html_response(conn, 200) =~ "Indexed Source"
    end

    test "renders the source status for Download Media on and off", %{conn: conn} do
      source_fixture(%{custom_name: "Downloading Source", download_media: true})
      source_fixture(%{custom_name: "Indexing Only Source", download_media: false})

      conn = get(conn, ~p"/sources?view=table")
      response = html_response(conn, 200)

      assert response =~ ~s(data-source-status="Enabled")
      assert response =~ ~s(data-source-status="Enabled, Download Media off")
    end

    test "renders source row controls", %{conn: conn} do
      source_fixture(%{custom_name: "Controllable Source"})

      conn = get(conn, ~p"/sources?view=table")
      response = html_response(conn, 200)

      assert response =~ "Start All"
      assert response =~ "Pause All"
      assert response =~ "Stop All"
      assert response =~ "Click again to start"
      assert response =~ "Click again to pause"
      assert response =~ "Click again to stop"
      refute response =~ "Start downloads for Controllable Source?"
    end

    test "renders the source delete control that opens the delete dialog", %{conn: conn} do
      source_fixture(%{custom_name: "Deletable Source"})

      conn = get(conn, ~p"/sources?view=table")
      response = html_response(conn, 200)

      assert response =~ ~s(aria-label="Delete Deletable Source")
      assert response =~ "confirm_delete"
      assert response =~ "delete-selected-sources-modal"
      assert response =~ "Delete Source"
    end

    test "defaults to the poster grid and honours an explicit table view", %{conn: conn} do
      source_fixture(%{custom_name: "View mode source"})

      default = conn |> get(~p"/sources") |> html_response(200)
      assert default =~ ~s(data-view="poster-grid")
      refute default =~ ~s(data-view="table")

      table = conn |> get(~p"/sources?view=table") |> html_response(200)
      assert table =~ ~s(data-view="table")
      refute table =~ ~s(data-view="poster-grid")
    end

    test "reopens the view the browser last chose", %{conn: conn} do
      source_fixture(%{custom_name: "Remembered view source"})
      source_fixture(%{custom_name: "Remembered view video", collection_type: :video})

      table = conn |> put_req_cookie("pinchflat_sources_view", "table") |> get(~p"/sources") |> html_response(200)
      assert table =~ ~s(data-view="table")

      videos =
        conn |> put_req_cookie("pinchflat_sources_view", "table") |> get(~p"/sources?type=videos") |> html_response(200)

      assert videos =~ ~s(data-view="table")

      explicit =
        conn |> put_req_cookie("pinchflat_sources_view", "table") |> get(~p"/sources?view=grid") |> html_response(200)

      assert explicit =~ ~s(data-view="poster-grid")

      unknown = conn |> put_req_cookie("pinchflat_sources_view", "sideways") |> get(~p"/sources") |> html_response(200)
      assert unknown =~ ~s(data-view="poster-grid")
    end

    test "the view toggle remembers the choice for later visits", %{conn: conn} do
      html = conn |> get(~p"/sources") |> html_response(200)

      assert html =~ "pinchflat_sources_view="
      assert html =~ ~s|x-on:click="remember('table')"|
    end

    test "starts the selected tab from the search term in the URL", %{conn: conn} do
      source_fixture(%{custom_name: "Zebra channel"})
      source_fixture(%{custom_name: "Other channel"})
      source_fixture(%{custom_name: "Zebra video", collection_type: :video})

      channels = conn |> get(~p"/sources?q=zebra") |> html_response(200)
      assert channels =~ "Zebra channel"
      refute channels =~ "Other channel"
      refute channels =~ "Zebra video"
      assert channels =~ ~s(id="source-search-input")

      videos = conn |> get(~p"/sources?type=videos&q=zebra") |> html_response(200)
      assert videos =~ "Zebra video"
      refute videos =~ "Zebra channel"
    end

    test "renders channel discovery in the sidebar", %{conn: conn} do
      response = conn |> get(~p"/sources") |> html_response(200)

      assert response =~ ~s(href="/discovery")
      assert response =~ "Channel Discovery"
    end
  end

  describe "import sources" do
    test "shows the upload form", %{conn: conn} do
      response = conn |> get(~p"/sources/import") |> html_response(200)
      assert response =~ "one YouTube channel, playlist, or video URL per line"
      assert response =~ "Media Profile"
    end

    test "previews each URL once without contacting providers or adding sources", %{
      conn: conn,
      create_attrs: attrs,
      extras_directory: directory
    } do
      valid_url = attrs.original_url
      path = Path.join(directory, "sources.txt")
      File.write!(path, "\n#{valid_url}\n#{valid_url}\nhttps://youtube.com/watch\n")
      upload = %Plug.Upload{path: path, filename: "sources.txt", content_type: "text/plain"}

      response =
        conn
        |> post(~p"/sources/import", import: %{file: upload, media_profile_id: to_string(attrs.media_profile_id)})
        |> html_response(200)

      assert response =~ "Review sources"
      assert response =~ "2 URLs to check"
      assert response =~ "1 repeated line skipped"
      assert Repo.aggregate(Pinchflat.Sources.Source, :count) == 0
    end

    test "rejects an empty file without adding sources", %{conn: conn, create_attrs: attrs, extras_directory: directory} do
      path = Path.join(directory, "empty.txt")
      File.write!(path, "\n  \n")
      upload = %Plug.Upload{path: path, filename: "empty.txt", content_type: "text/plain"}

      response =
        conn
        |> post(~p"/sources/import", import: %{file: upload, media_profile_id: to_string(attrs.media_profile_id)})
        |> html_response(200)

      assert response =~ "1 to 100 URLs"
      assert Repo.aggregate(Pinchflat.Sources.Source, :count) == 0
    end
  end

  describe "new source" do
    test "preselects a media profile", %{conn: conn, create_attrs: %{media_profile_id: profile_id}} do
      response = conn |> get(~p"/sources/new") |> html_response(200)

      assert response =~
               ~r/<input[^>]*id="source_media_profile_id"[^>]*value="#{profile_id}"/
    end

    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ "New Source"
      assert response =~ "Source Type"
      assert response =~ "Automatic"
      assert response =~ "Channel"
      assert response =~ "Playlist"
      assert response =~ "Video"
      assert response =~ "Channel URL"
      assert response =~ "Playlist URL"
      assert response =~ "Video URL"
      assert response =~ "preserves existing Pinchflat-ngx behavior."
      refute response =~ ~S(Pinchflat-ngx\'s)
      assert response =~ "Source Metadata"
      refute response =~ "Lock Source Name"
      refute response =~ "Lock Description"
      assert response =~ "Follow the channel again"
      assert response =~ ~s(name="source[custom_name_locked]" value="false")
      assert response =~ ~s(name="source[description_locked]" value="false")
      assert response =~ ~s(x-on:input="locked = true")
      refute %Pinchflat.Sources.Source{}.download_members_only_media
      assert response =~ "Delay Automatic Download"
      assert response =~ "Download Public and Unlisted Media"
      assert response =~ "Download Members-only Media"
      assert response =~ "YouTube Player Client"
      assert response =~ "Default"
      assert response =~ "Web Creator"
      assert response =~ "Members-only media may fail without cookies"
      assert response =~ "How source folders work"
      assert response =~ "Insert media profile template"
    end

    test "prefills the source form from discovery query params", %{conn: conn} do
      original_url = "https://www.youtube.com/@pinchflattest"
      custom_name = "A discovered channel"

      response =
        conn
        |> get(~p"/sources/new", %{
          "original_url" => original_url,
          "custom_name" => custom_name,
          "source_type" => "channel"
        })
        |> html_response(200)

      assert response =~ ~s(value="#{original_url}")
      assert response =~ ~s(value="#{custom_name}")
      assert response =~ "sourceType: &#39;channel&#39;"
    end

    test "enriches the source form when only original_url is provided", %{conn: conn} do
      original_url = "https://www.youtube.com/@enriched-channel"

      expect(YtDlpRunnerMock, :run, fn ^original_url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Pinchflat.SourcesFixtures.source_details_return_fixture(%{
           channel: "Enriched Channel",
           playlist_channel: "Enriched Channel",
           playlist_channel_id: "UCenriched",
           playlist_id: "UCenriched",
           playlist_title: "Enriched Channel"
         })}
      end)

      response = conn |> get(~p"/sources/new", %{"original_url" => original_url}) |> html_response(200)

      assert response =~ ~s(value="#{original_url}")
      assert response =~ ~s(value="Enriched Channel")
      assert response =~ "sourceType: &#39;channel&#39;"
    end

    test "prefills boolean query params on the new source form", %{conn: conn} do
      response =
        conn
        |> get(~p"/sources/new", %{
          "original_url" => "https://www.youtube.com/watch?v=72maj9FLQZI",
          "custom_name" => "Locked name",
          "source_type" => "video",
          "custom_name_locked" => "true",
          "download_members_only_media" => "false"
        })
        |> html_response(200)

      assert response =~ ~s(value="Locked name")
      assert response =~ ~s(name="source[custom_name_locked]" value="true")
      assert response =~ ~s(name="source[download_members_only_media]" value="false")
    end

    test "ignores an invalid source type prefill", %{conn: conn} do
      response =
        conn
        |> get(~p"/sources/new", %{"source_type" => "not-a-source-type"})
        |> html_response(200)

      assert response =~ "sourceType: &#39;automatic&#39;"
      refute response =~ "not-a-source-type"
    end

    test "renders source folder picker options from saved source folders", %{conn: conn} do
      media_root = Path.join(System.tmp_dir!(), "pinchflat-source-folder-picker-#{System.unique_integer([:positive])}")
      original_media_root = Application.get_env(:pinchflat, :media_directory)

      Application.put_env(:pinchflat, :media_directory, media_root)
      File.mkdir_p!(Path.join([media_root, "Kids", "Bluey"]))
      File.mkdir_p!(Path.join([media_root, "DiskOnly"]))
      source_fixture(%{download_subdirectory: "Kids"})
      source_fixture(%{download_subdirectory: "Kids/Bluey"})

      on_exit(fn ->
        Application.put_env(:pinchflat, :media_directory, original_media_root)
        File.rm_rf!(media_root)
      end)

      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ "Pick existing source folder"
      assert response =~ "Kids"
      assert response =~ "Kids/Bluey"
      refute response =~ ~s(data-folder="DiskOnly")
    end

    test "renders cookie management controls", %{conn: conn} do
      File.write!(Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt"), "youtube-cookie-data")

      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ "Upload cookies.txt"
      assert response =~ "Paste Cookie Contents"
      assert response =~ "Inspect Cookie File"
      assert response =~ "Cookie file is configured and ready to use."
    end

    test "defaults cookie behaviour to all operations when cookies.txt exists", %{conn: conn} do
      File.write!(Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt"), "youtube-cookie-data")

      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ ~r/<input[^>]*type="hidden"[^>]*name="source\[cookie_behaviour\]"[^>]*value="all_operations"/
    end

    test "renders correct layout when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = get(conn, ~p"/sources/new")

      refute html_response(conn, 200) =~ "MENU"
    end

    test "preloads some attributes when using a template", %{conn: conn} do
      source = source_fixture(custom_name: "My first source", download_cutoff_date: "2021-01-01")

      conn = get(conn, ~p"/sources/new", %{"template_id" => source.id})
      assert html_response(conn, 200) =~ "New Source"
      assert html_response(conn, 200) =~ "2021-01-01"
      refute html_response(conn, 200) =~ source.custom_name
    end
  end

  describe "create source" do
    test "saves an explicit channel when the first video has no channel metadata", %{
      conn: conn,
      create_attrs: create_attrs
    } do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        Phoenix.json_library().encode(%{
          playlist_channel: "Channel owner",
          playlist_channel_id: "UCowner",
          playlist_id: "UCowner",
          playlist_title: "Channel owner - Videos"
        })
      end)

      attrs =
        Map.merge(create_attrs, %{source_type: "channel", original_url: "https://www.youtube.com/@noiraeris/videos"})

      conn = post(conn, ~p"/sources", source: attrs)

      assert %{id: id} = redirected_params(conn)
      source = Pinchflat.Sources.get_source!(id)
      assert source.collection_type == :channel
      assert source.collection_id == "UCowner"
      assert source.collection_name == "Channel owner"
    end

    test "redirects to show when data is valid", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}"

      conn = get(conn, ~p"/sources/#{id}")
      assert html_response(conn, 200) =~ "Source"
    end

    test "renders errors when data is invalid", %{conn: conn, invalid_attrs: invalid_attrs} do
      conn = post(conn, ~p"/sources", source: invalid_attrs)
      assert html_response(conn, 200) =~ "New Source"
    end

    test "preserves the selected source type and URL after an inspection error", %{
      conn: conn,
      create_attrs: create_attrs
    } do
      source_attrs =
        Map.merge(create_attrs, %{
          source_type: "video",
          original_url: "https://www.youtube.com/channel/explicit-video-mismatch"
        })

      response = conn |> post(~p"/sources", source: source_attrs) |> html_response(200)

      assert response =~ "could not inspect this URL as a Video"
      assert response =~ ~r/name="source\[source_type\]"[^>]*value="video"/
      assert response =~ "https://www.youtube.com/channel/explicit-video-mismatch"
      assert response =~ "Video URL"
    end

    test "renders a cookie compatibility error for the selected player client", %{
      conn: conn,
      create_attrs: create_attrs
    } do
      conn =
        post(conn, ~p"/sources", source: Map.merge(create_attrs, %{player_client: "web_creator"}))

      assert html_response(conn, 200) =~ "requires account cookies; select When Needed or All Operations"
    end

    test "redirects to onboarding when onboarding", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert redirected_to(conn) == ~p"/?onboarding=1"
    end

    test "redirects to show for a single video URL", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           id: "72maj9FLQZI",
           title: "One-Off Video",
           channel: "PinchflatTestChannel",
           channel_id: "UCQH2",
           playlist_id: nil,
           playlist_title: nil,
           filename: "/tmp/test/media/one-off.mp4"
         })}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            media_profile_id: media_profile_fixture().id,
            original_url: "https://www.youtube.com/watch?v=72maj9FLQZI"
          }
        )

      assert %{id: _id} = redirected_params(conn)
    end

    test "redirects playlists with delayed automatic download to the selection tab", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: nil,
           channel_id: nil,
           playlist_id: "some_playlist_id_123",
           playlist_title: "Some Playlist"
         })}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            media_profile_id: media_profile_fixture().id,
            original_url: "https://www.youtube.com/playlist?list=PL1234567890ABCDEF",
            delay_automatic_download: "true"
          }
        )

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}?#{[tab: "selection"]}"
    end

    test "redirects normal playlists to the source page and leaves auto download enabled", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: nil,
           channel_id: nil,
           playlist_id: "some_playlist_id_123",
           playlist_title: "Some Playlist"
         })}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            media_profile_id: media_profile_fixture().id,
            original_url: "https://www.youtube.com/playlist?list=PL1234567890ABCDEF"
          }
        )

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}"

      source = Pinchflat.Sources.get_source!(id)
      assert source.selection_mode == :all
      assert source.download_media
    end

    test "renders correct layout on error when onboarding", %{conn: conn, invalid_attrs: invalid_attrs} do
      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: invalid_attrs)

      refute html_response(conn, 200) =~ "MENU"
    end
  end

  describe "edit source" do
    setup [:create_source]

    test "renders form for editing chosen source", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/edit")
      response = html_response(conn, 200)
      assert response =~ "Editing \"#{source.custom_name}\""
      assert response =~ "name=\"source[description]\""
      assert response =~ "name=\"source[custom_name_locked]\""
      assert response =~ "name=\"source[description_locked]\""
    end

    test "renders custom poster controls", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/edit")
      response = html_response(conn, 200)

      assert response =~ "Custom Source Poster"
      assert response =~ "name=\"poster[file]\""
      assert response =~ "name=\"poster[url]\""
      refute response =~ "Remove Custom Poster"
    end

    test "renders restore automatic downloads action for manual playlists", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      conn = get(conn, ~p"/sources/#{source}/edit")

      assert html_response(conn, 200) =~ "Restore Automatic Downloads"
    end

    test "does not override saved cookie behaviour on edit when cookies.txt exists", %{conn: conn, source: source} do
      File.write!(Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt"), "youtube-cookie-data")
      source = Repo.reload!(source)

      conn = get(conn, ~p"/sources/#{source}/edit")
      response = html_response(conn, 200)

      assert response =~ ~r/<input[^>]*type="hidden"[^>]*name="source\[cookie_behaviour\]"[^>]*value="disabled"/
      refute response =~ ~r/<input[^>]*type="hidden"[^>]*name="source\[cookie_behaviour\]"[^>]*value="all_operations"/
    end
  end

  describe "source form layout" do
    test "shows every setting without an editing mode, advanced ones in closed groups", %{conn: conn} do
      source = source_fixture(title_filter_regex: "(?i)live")
      response = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      refute response =~ "advancedMode"
      refute response =~ "Editing Mode"
      assert response =~ ~s(name="source[min_duration_seconds]")
      assert response =~ ~r/<summary[^>]*>(?:(?!<\/summary>).)*Title filter(?:(?!<\/summary>).)*Enabled/s
      refute response =~ ~r/<summary[^>]*>(?:(?!<\/summary>).)*Title filter(?:(?!<\/summary>).)*\(\?i\)live/s
      assert response =~ ~r/<summary[^>]*>.*?Custom yt-dlp options.*?No local options.*?<\/summary>/s
      refute response =~ ~r/<details[^>]*\sopen/
    end

    test "puts the raw regex after the word lists and the tester in a closed group", %{conn: conn} do
      response = conn |> get(~p"/sources/new") |> html_response(200)

      regex_field = position(response, ~s(name="source[title_filter_regex]"))
      assert position(response, ~s(data-title-filter-list="none")) < regex_field
      assert position(response, ~s(aria-label="Clear title filter")) > regex_field
      assert regex_field < position(response, "Test this filter")
      assert response =~ ~r/<summary[^>]*>(?:(?!<\/summary>).)*Test this filter/s
      refute response =~ ~r/<summary[^>]*>(?:(?!<\/summary>).)*Title Filter Regex/s
      refute response =~ ">Preview<"
    end

    test "renders the raw regex field below the title filter word lists on new and edit pages", %{conn: conn} do
      source = source_fixture(title_filter_regex: "(?i)^(?=.*(?<!\\w)live(?!\\w)).*$")

      for path <- [~p"/sources/new", ~p"/sources/#{source}/edit"] do
        response = conn |> get(path) |> html_response(200)

        assert response =~ "data-title-filter-builder"
        assert response =~ "pinchflatTitleFilterBuilder("
        assert response =~ ~s(name="source[title_filter_regex]")
        regex_field = position(response, ~s(name="source[title_filter_regex]"))
        assert position(response, ~s(data-title-filter-list="none")) < regex_field
      end
    end

    test "gives each title filter word list its own switches and info tips", %{conn: conn} do
      response = conn |> get(~p"/sources/new") |> html_response(200)

      for key <- ~w(any all none) do
        assert response =~ ~s(data-title-filter-list="#{key}")
        assert response =~ ~s(id="title-filter-#{key}-whole")
        assert response =~ ~s(x-model="options.#{key}.whole")
        assert response =~ ~s(id="title-filter-#{key}-case")
        assert response =~ ~s(x-model="options.#{key}.matchCase")
        assert response =~ ~s(aria-describedby="title-filter-#{key}-tip")
      end

      assert response =~ "If the title has any of these, the video is skipped."
      assert response =~ ~s(Off lets &quot;art&quot; match &quot;party&quot;.)
    end

    test "renders the title filter conflict notice inside the builder", %{conn: conn} do
      response = conn |> get(~p"/sources/new") |> html_response(200)

      assert [_, after_builder] = String.split(response, "data-title-filter-builder", parts: 2)
      assert after_builder =~ "data-title-filter-conflicts"
      assert after_builder =~ "This filter contradicts itself"
    end

    test "seeds the title filter builder with the saved regex", %{conn: conn} do
      source = source_fixture(title_filter_regex: "(?i)^(?=.*(?<!\\w)live(?!\\w)).*$")
      response = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert response =~ ~r/pinchflatTitleFilterBuilder\(&quot;\(\?i\)\^\(\?=\.\*\(\?&lt;!\\\\w\)live/
    end

    test "opens the title filter group when its regex is invalid", %{conn: conn} do
      source = source_fixture()
      conn = put(conn, ~p"/sources/#{source}", source: %{title_filter_regex: "(unclosed"})
      response = html_response(conn, 200)

      assert [opened] = Regex.scan(~r/<details[^>]*\sopen[^>]*>.*?<\/summary>/s, response)
      assert hd(opened) =~ "Title filter"
    end

    test "renders section navigation, the settings search and collapsed groups", %{conn: conn} do
      response = conn |> get(~p"/sources/new") |> html_response(200)

      for id <- ~w(source-general source-metadata source-indexing source-downloading source-cleanup source-advanced) do
        assert response =~ ~s(id="#{id}")
        assert response =~ ~s(href="##{id}")
      end

      assert response =~ ~s(id="setting-search")
      refute response =~ ~s(aria-label="Settings in )
      assert response =~ "lg:bg-theme-surface-2"
      assert response =~ ~r/id="source-general"[^>]*theme-surface-raised/
      refute response =~ ~r/<section\s+id="source-[a-z-]+"[^>]*border-t/
      assert response =~ ~s(id="source-shared-cookies")
      assert response =~ "YouTube player client"
      assert response =~ "Retention and watch window"
      assert response =~ "Output path template overrides"
      refute response =~ ~r/<details[^>]*\sopen/
    end

    test "renders both cutoff dates as date pickers", %{conn: conn} do
      source = source_fixture(download_cutoff_date: ~D[2026-10-17], index_cutoff_date: ~D[2026-10-10])
      response = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert response =~ ~r/<input[^>]*id="source_download_cutoff_date"[^>]*value="2026-10-17"/
      assert response =~ ~r/<input[^>]*id="source_index_cutoff_date"[^>]*value="2026-10-10"/
      assert response =~ ~s(aria-controls="source_download_cutoff_date-calendar")
      assert response =~ ~s(aria-controls="source_index_cutoff_date-calendar")
    end

    test "opens a collapsed group when one of its fields has an error", %{conn: conn} do
      source = source_fixture()
      conn = put(conn, ~p"/sources/#{source}", source: %{watch_window_days: 9999})
      response = html_response(conn, 200)

      assert [opened] = Regex.scan(~r/<details[^>]*\sopen[^>]*>.*?<\/summary>/s, response)
      assert hd(opened) =~ "Retention and watch window"
    end
  end

  describe "download cutoff modes" do
    setup [:create_source]

    test "creates a source with a rolling cutoff", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn =
        post(conn, ~p"/sources",
          source: Map.merge(create_attrs, %{download_cutoff_days: "30", download_cutoff_date: ""})
        )

      assert %{id: id} = redirected_params(conn)
      source = Repo.get!(Pinchflat.Sources.Source, id)
      assert source.download_cutoff_days == 30
      assert is_nil(source.download_cutoff_date)
    end

    test "renders the cutoff mode selector and the rolling value", %{conn: conn} do
      source = source_fixture(download_cutoff_days: 30)
      media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-10-24 12:00:00Z]})

      html = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert html =~ ~s(id="source-cutoff-mode")
      assert html =~ ~s(<option value="days")
      assert html =~ "Rolling window (last N days)"
      assert html =~ ~r/id="source_download_cutoff_days"[^>]*value="30"/
      assert html =~ ~r/cutoffMode: (?:'|&#39;)days(?:'|&#39;)/
      assert html =~ "cutoffWarningCount"
      assert html =~ "2026-10-24"
    end

    test "switches between rolling, fixed, and no cutoff", %{conn: conn, source: source} do
      conn = put(conn, ~p"/sources/#{source}", source: %{download_cutoff_date: "", download_cutoff_days: "30"})
      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert updated.download_cutoff_days == 30
      assert is_nil(updated.download_cutoff_date)

      conn = put(conn, ~p"/sources/#{source}", source: %{download_cutoff_date: "2026-07-01", download_cutoff_days: ""})
      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert updated.download_cutoff_date == ~D[2026-07-01]
      assert is_nil(updated.download_cutoff_days)

      conn = put(conn, ~p"/sources/#{source}", source: %{download_cutoff_date: "", download_cutoff_days: ""})
      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert is_nil(updated.download_cutoff_date)
      assert is_nil(updated.download_cutoff_days)
    end

    test "rejects a submission that sets both cutoff forms", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}", source: %{download_cutoff_date: "2026-07-01", download_cutoff_days: "30"})

      assert html_response(conn, 200) =~ "must be blank when a download cutoff date is set"
    end

    test "shows the rolling cutoff on the source overview", %{conn: conn} do
      source = source_fixture(download_cutoff_days: 30)
      expected = Date.utc_today() |> Date.add(-30) |> Calendar.strftime("%b %-d, %Y")

      html = conn |> get(~p"/sources/#{source}?#{[tab: "source"]}") |> html_response(200)

      assert html =~ "Rolling 30 days (currently #{expected})"
    end
  end

  describe "title language" do
    setup [:create_source]

    test "saves the source title language and redisplays it on the form", %{conn: conn, source: source} do
      conn = put(conn, ~p"/sources/#{source}", source: %{title_language: "ZH-cn"})
      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"
      assert Repo.reload!(source).title_language == "zh-CN"

      html = conn |> recycle() |> get(~p"/sources/#{source}/edit") |> html_response(200)
      assert html =~ ~r/id="source_title_language"[^>]*value="zh-CN"/
      assert html =~ ~r/<summary[^>]*>.*?Title language.*?zh-CN.*?<\/summary>/s
    end

    test "shows the default summary when no title language is set", %{conn: conn} do
      html = conn |> get(~p"/sources/new") |> html_response(200)

      assert html =~ ~s(name="source[title_language]")
      assert html =~ ~r/<summary[^>]*>.*?Title language.*?Default \(channel language\).*?<\/summary>/s
    end

    test "shows a validation error for an invalid title language", %{conn: conn, source: source} do
      response =
        conn
        |> put(~p"/sources/#{source}", source: %{title_language: "invalid_code"})
        |> html_response(200)

      assert response =~ "must be a YouTube language code such as en, ja, pt-PT or zh-CN"
      assert [opened] = Regex.scan(~r/<details[^>]*\sopen[^>]*>.*?<\/summary>/s, response)
      assert hd(opened) =~ "Title language"
    end
  end

  describe "title filter test" do
    test "reports which sample and indexed titles the regex matches", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(source_id: source.id, title: "How to Bike")

      conn =
        post(conn, ~p"/sources/title_filter/test", %{
          "regex" => "(?i)bike",
          "titles" => "Bike repair\n\nCooking pasta",
          "source_id" => to_string(source.id)
        })

      assert json_response(conn, 200) == %{
               "samples" => [
                 %{"title" => "Bike repair", "match" => true},
                 %{"title" => "Cooking pasta", "match" => false}
               ],
               "indexed" => [%{"title" => "How to Bike", "match" => true}]
             }
    end

    test "checks only sample titles for a source that is not saved yet", %{conn: conn} do
      conn =
        post(conn, ~p"/sources/title_filter/test", %{"regex" => "^Live", "titles" => "Live at five", "source_id" => ""})

      assert json_response(conn, 200) == %{
               "samples" => [%{"title" => "Live at five", "match" => true}],
               "indexed" => []
             }
    end

    test "asks for a regex when it is blank", %{conn: conn} do
      conn = post(conn, ~p"/sources/title_filter/test", %{"regex" => "  ", "titles" => "Anything"})

      assert json_response(conn, 422) == %{"error" => "Enter a regex to test."}
    end

    test "explains a regex the database cannot use", %{conn: conn} do
      conn = post(conn, ~p"/sources/title_filter/test", %{"regex" => "(unclosed", "titles" => "Anything"})

      assert %{"error" => "The database could not use this regex" <> _} = json_response(conn, 422)
    end
  end

  describe "cookie file actions" do
    test "save_cookies writes cookie contents and redirects back", %{conn: conn, extras_directory: extras_directory} do
      conn =
        post(conn, ~p"/sources/cookies/save", %{
          "cookies" => %{"contents" => "youtube-cookie-data"},
          "return_to" => "/sources/new"
        })

      assert redirected_to(conn) == "/sources/new"
      assert File.read!(Path.join(extras_directory, "cookies.txt")) == "youtube-cookie-data"
    end

    test "upload_cookies copies the uploaded file and redirects back", %{conn: conn, extras_directory: extras_directory} do
      upload_path = Path.join(extras_directory, "uploaded-cookies.txt")
      File.write!(upload_path, "uploaded-youtube-cookie-data")

      upload = %Plug.Upload{
        path: upload_path,
        filename: "cookies.txt",
        content_type: "text/plain"
      }

      conn = post(conn, ~p"/sources/cookies/upload", %{"cookies" => %{"file" => upload}, "return_to" => "/sources/new"})

      assert redirected_to(conn) == "/sources/new"
      assert File.read!(Path.join(extras_directory, "cookies.txt")) == "uploaded-youtube-cookie-data"
    end
  end

  describe "custom poster actions" do
    test "uploads a custom poster and redirects back to edit", %{conn: conn} do
      source = source_fixture()

      upload = %Plug.Upload{
        path: thumbnail_filepath_fixture(),
        filename: "poster.jpg",
        content_type: "image/jpeg"
      }

      conn = post(conn, ~p"/sources/#{source}/poster/upload", %{"poster" => %{"file" => upload}})

      assert redirected_to(conn) == ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Custom poster saved."
      assert Repo.reload!(source).custom_poster_filename
    end

    test "removes a custom poster and redirects back to edit", %{conn: conn} do
      source = source_fixture()

      {:ok, source} =
        CustomPoster.set_from_upload(source, %Plug.Upload{
          path: thumbnail_filepath_fixture(),
          filename: "poster.jpg",
          content_type: "image/jpeg"
        })

      custom_filepath = CustomPoster.filepath(source)
      conn = post(conn, ~p"/sources/#{source}/poster/remove")

      assert redirected_to(conn) == ~p"/sources/#{source}/edit"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Custom poster removed. The fetched poster will be used again."

      assert is_nil(Repo.reload!(source).custom_poster_filename)
      refute File.exists?(custom_filepath)
    end

    test "reports invalid poster URLs without fetching them", %{conn: conn} do
      source = source_fixture()
      expect(HTTPClientMock, :get, 0, fn _url, [], _opts -> {:ok, ""} end)

      conn = post(conn, ~p"/sources/#{source}/poster/url", %{"poster" => %{"url" => "file:///etc/passwd"}})

      assert redirected_to(conn) == ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Enter a public HTTP(S) poster URL."
    end
  end

  describe "update source" do
    setup [:create_source]

    test "shows Shorts template validation errors before directory move confirmation", %{conn: conn, source: source} do
      conn = put(conn, ~p"/sources/#{source}", source: %{output_path_template_shorts_override: "invalid.mp4"})
      assert html_response(conn, 200) =~ "must end with .{{ ext }}"
    end

    test "redirects when data is valid", %{conn: conn, source: source, update_attrs: update_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn = put(conn, ~p"/sources/#{source}", source: update_attrs)
      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      conn = get(conn, ~p"/sources/#{source}")
      assert html_response(conn, 200) =~ "https://www.youtube.com/playlist?list=PL1234567890ABCDEF"
    end

    test "renders errors when data is invalid", %{
      conn: conn,
      source: source,
      invalid_attrs: invalid_attrs
    } do
      conn = put(conn, ~p"/sources/#{source}", source: invalid_attrs)
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end

    test "marks a staged reconcile plan stale", %{conn: conn, source: source, update_attrs: update_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)
      {:ok, plan} = Pinchflat.Reconciliation.create_plan(%{mode: :local, status: :ready})

      put(conn, ~p"/sources/#{source}", source: update_attrs)

      assert Pinchflat.Reconciliation.get_plan!(plan.id).status == :stale
    end

    test "persists availability policy settings", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{download_public_media: "false", download_members_only_media: "false"}
        )

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"
      updated_source = Repo.reload!(source)
      refute updated_source.download_public_media
      refute updated_source.download_members_only_media
    end
  end

  describe "playlist owner lock" do
    test "PUT persists only_owner_uploads", %{conn: conn} do
      source = source_fixture(collection_type: :playlist, only_owner_uploads: false)

      conn = put(conn, ~p"/sources/#{source}", source: %{only_owner_uploads: "true"})

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"
      assert Repo.reload!(source).only_owner_uploads
    end

    test "edit form renders the toggle for a playlist source", %{conn: conn} do
      source = source_fixture(collection_type: :playlist)

      html = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert html =~ "Only download videos uploaded by the playlist owner"
    end

    test "edit form keeps the toggle inside the playlist-only section", %{conn: conn} do
      source = source_fixture(collection_type: :channel)

      html = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert html =~ ~r/<section[^>]*x-show="isPlaylist"[^>]*>.*?only_owner_uploads.*?<\/section>/s
    end

    test "source page shows owner rows only for playlists", %{conn: conn} do
      playlist =
        source_fixture(
          collection_type: :playlist,
          owner_channel_id: "UCplaylistowner",
          only_owner_uploads: true
        )

      channel = source_fixture(collection_type: :channel, owner_channel_id: "UCchannelowner")

      playlist_html = conn |> get(~p"/sources/#{playlist}?#{[tab: "source"]}") |> html_response(200)
      assert playlist_html =~ "Owner channel"
      assert playlist_html =~ "UCplaylistowner"
      assert playlist_html =~ "Only owner uploads"
      assert playlist_html =~ "Yes"

      channel_html = conn |> get(~p"/sources/#{channel}?#{[tab: "source"]}") |> html_response(200)
      refute channel_html =~ "Owner channel"
      refute channel_html =~ "Only owner uploads"
    end

    test "JSON show returns owner lock fields", %{conn: conn} do
      source =
        source_fixture(
          collection_type: :playlist,
          owner_channel_id: "UCplaylistowner",
          only_owner_uploads: true
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/sources/#{source}")
        |> json_response(200)

      assert response["owner_channel_id"] == "UCplaylistowner"
      assert response["only_owner_uploads"] == true
    end
  end

  describe "keep newest confirmation" do
    test "lowering the limit shows the removal count before saving", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: 5, download_media: false})

      create_cullable_items(source, 5)

      html = conn |> put(~p"/sources/#{source}", source: %{keep_newest_count: "2"}) |> html_response(200)

      assert html =~ "Confirm Keep Newest Limit"
      assert html =~ "3 older downloads"
      assert html =~ ~s(name="confirm_keep_newest")
      assert Repo.reload!(source).keep_newest_count == 5
    end

    test "the confirmation resubmits yt-dlp options and list params", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: 5, download_media: false})

      create_cullable_items(source, 5)

      html =
        conn
        |> put(~p"/sources/#{source}", %{
          "source" => %{"keep_newest_count" => "2", "example_list" => ["", "a"]},
          "yt_dlp_options" => "--no-mtime",
          "yt_dlp_options_version" => "any"
        })
        |> html_response(200)

      assert html =~ ~s(name="yt_dlp_options" value="--no-mtime")
      assert html =~ ~s(name="yt_dlp_options_version" value="any")
      assert html =~ ~s(name="source[example_list][]" value="a")
    end

    test "the confirmation omits yt-dlp options that were not submitted", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: 5, download_media: false})

      create_cullable_items(source, 5)

      html = conn |> put(~p"/sources/#{source}", source: %{keep_newest_count: "2"}) |> html_response(200)

      refute html =~ ~s(name="yt_dlp_options")
    end

    test "confirming persists the new limit and redirects", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: 5, download_media: false})

      create_cullable_items(source, 5)

      conn =
        put(conn, ~p"/sources/#{source}", %{"source" => %{"keep_newest_count" => "2"}, "confirm_keep_newest" => "true"})

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"
      assert Repo.reload!(source).keep_newest_count == 2
    end

    test "setting a limit with no removable files updates without confirmation", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: nil, download_media: false})

      conn = put(conn, ~p"/sources/#{source}", source: %{keep_newest_count: "3"})

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"
      assert Repo.reload!(source).keep_newest_count == 3
    end

    test "rejects a zero or negative limit with a changeset error", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: nil, download_media: false})

      for invalid <- ["0", "-1"] do
        conn = put(conn, ~p"/sources/#{source}", source: %{keep_newest_count: invalid})
        assert html_response(conn, 200) =~ "must be greater than 0"
      end

      assert Repo.reload!(source).keep_newest_count == nil
    end
  end

  describe "update source SponsorBlock overrides" do
    setup [:create_source]

    test "inherit mode stores nil so the profile list keeps applying", %{conn: conn, source: source} do
      {:ok, source} =
        Pinchflat.Sources.update_source(source, %{
          sponsorblock_mark_categories: ["intro"],
          sponsorblock_remove_categories: ["sponsor"]
        })

      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{
            "sponsorblock_mark_mode" => "inherit",
            "sponsorblock_remove_mode" => "inherit"
          }
        )

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert updated.sponsorblock_mark_categories == nil
      assert updated.sponsorblock_remove_categories == nil
    end

    test "disable mode stores an empty list", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{
            "sponsorblock_remove_mode" => "disable",
            "sponsorblock_mark_mode" => "disable"
          }
        )

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert updated.sponsorblock_remove_categories == []
      assert updated.sponsorblock_mark_categories == []
    end

    test "custom mode stores the selected categories", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{
            "sponsorblock_remove_mode" => "custom",
            "sponsorblock_remove_categories" => ["sponsor", "selfpromo"],
            "sponsorblock_mark_mode" => "custom",
            "sponsorblock_mark_categories" => ["intro"]
          }
        )

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert updated.sponsorblock_remove_categories == ["sponsor", "selfpromo"]
      assert updated.sponsorblock_mark_categories == ["intro"]
    end

    test "mark and remove inherit independently", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{
            "sponsorblock_remove_mode" => "disable",
            "sponsorblock_mark_mode" => "inherit"
          }
        )

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "source"]}"

      updated = Repo.reload!(source)
      assert updated.sponsorblock_remove_categories == []
      assert updated.sponsorblock_mark_categories == nil
    end

    test "renders an unknown category error", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{
            "sponsorblock_remove_mode" => "custom",
            "sponsorblock_remove_categories" => ["sponsor", "not_a_category"]
          }
        )

      html = html_response(conn, 200)
      assert html =~ "Editing"
      assert Repo.reload!(source).sponsorblock_remove_categories == nil
    end

    test "renders an overlap error when a category is both marked and removed", %{conn: conn, source: source} do
      conn =
        put(conn, ~p"/sources/#{source}",
          source: %{
            "sponsorblock_remove_mode" => "custom",
            "sponsorblock_remove_categories" => ["sponsor", "intro"],
            "sponsorblock_mark_mode" => "custom",
            "sponsorblock_mark_categories" => ["intro"]
          }
        )

      html = html_response(conn, 200)
      assert html =~ "can&#39;t mark and remove the same category: intro"
      assert Repo.reload!(source).sponsorblock_mark_categories == nil
    end

    test "the form explains the effect and offers all three modes", %{conn: conn, source: source} do
      html = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert html =~ "Applies to future downloads, quality upgrades and redownloads. Existing files are never re-cut."
      assert html =~ "Inherit from the media profile"
      assert html =~ "Off for this source"
      assert html =~ "Choose categories for this source"
      assert html =~ ~s(name="source[sponsorblock_mark_mode]")
      assert html =~ ~s(name="source[sponsorblock_remove_mode]")
    end

    test "the source page shows the inherit, off and custom states", %{conn: conn} do
      profile =
        media_profile_fixture(%{
          sponsorblock_remove_categories: ["sponsor"],
          sponsorblock_mark_categories: ["intro"]
        })

      inheriting = source_fixture(media_profile_id: profile.id)
      disabled = source_fixture(media_profile_id: profile.id, sponsorblock_remove_categories: [])
      custom = source_fixture(media_profile_id: profile.id, sponsorblock_remove_categories: ["selfpromo"])

      inherit_html = conn |> get(~p"/sources/#{inheriting}?#{[tab: "source"]}") |> html_response(200)
      assert inherit_html =~ "Inherit (Sponsor)"

      disabled_html = conn |> get(~p"/sources/#{disabled}?#{[tab: "source"]}") |> html_response(200)
      assert disabled_html =~ "Off"

      custom_html = conn |> get(~p"/sources/#{custom}?#{[tab: "source"]}") |> html_response(200)
      assert custom_html =~ "Custom (Self Promotion)"
    end

    test "using a source as a template keeps its SponsorBlock overrides", %{conn: conn} do
      source =
        source_fixture(%{
          sponsorblock_mark_categories: ["intro"],
          sponsorblock_remove_categories: []
        })

      html = conn |> get(~p"/sources/new?template_id=#{source.id}") |> html_response(200)

      assert html =~ ~s(value="custom")
      assert html =~ "Inherit from the media profile"
    end
  end

  describe "delete source in all cases" do
    setup [:create_source]

    test "redirects to the sources page", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}")
      assert redirected_to(conn) == ~p"/sources"
    end

    test "sets marked_for_deletion_at", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")
      assert Repo.reload!(source).marked_for_deletion_at
    end

    test "returns to Individual videos after deletion", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}", %{"return_to" => "/sources?type=videos"})
      assert redirected_to(conn) == "/sources?type=videos"
      assert Repo.reload!(source).marked_for_deletion_at
      assert_enqueued(worker: SourceDeletionWorker)
    end

    test "rejects an external return destination after deletion", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}", %{"return_to" => "https://example.com"})
      assert redirected_to(conn) == "/sources"
    end
  end

  describe "delete source when just deleting the records" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")

      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "delete source when deleting the records and files" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}?delete_files=true")

      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "force_download_pending" do
    test "enqueues pending download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert [%{args: %{"reset_last_error" => true}}] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end

    test "explains that downloads are disabled instead of reporting a queue count", %{conn: conn} do
      source = source_fixture(%{download_media: false})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")

      assert redirected_to(conn) == ~p"/sources/#{source.id}"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Downloads are disabled for this source. No jobs were queued."

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
      refute_enqueued(worker: MediaDownloadWorker)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "reports the existing no-op summary for an enabled source with no pending items", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "0 queued, 0 already queued, 0 failed."
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "replaces non-executing pending tasks and reports queued items when forcing download of already queued items",
         %{conn: conn} do
      source = source_fixture()
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      assert {:ok, initial_task} = MediaDownloadWorker.kickoff_with_task(media_item)

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")

      assert redirected_to(conn) == ~p"/sources/#{source.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "1 queued, 0 already queued, 0 failed."

      assert [persisted] = Tasks.list_tasks_for(media_item)
      assert persisted.id != initial_task.id
    end

    test "reports already queued items when pending download task is executing", %{conn: conn} do
      source = source_fixture()
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      # Oban's uniqueness key includes args, so this executing job must match the
      # retry args to conflict instead of being replaced.
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item, %{"reset_last_error" => true})
      job = Repo.get!(Oban.Job, task.job_id)
      job |> Ecto.Changeset.change(%{state: "executing"}) |> Repo.update!()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")

      assert redirected_to(conn) == ~p"/sources/#{source.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "0 queued, 1 already queued, 0 failed."
    end
  end

  describe "show source" do
    test "section tabs carry the scroll position to the next tab", %{conn: conn} do
      source = source_fixture()
      html = conn |> get(~p"/sources/#{source}?#{[tab: "pending"]}") |> html_response(200)

      assert html =~ ~s|x-on:click="rememberScroll($event)"|
      assert html =~ "restoreScroll();"
    end

    test "marks the requested page section and keeps source-only controls out of other sections", %{conn: conn} do
      source = source_fixture()
      html = conn |> get(~p"/sources/#{source}?#{[tab: "podcast"]}") |> html_response(200)

      assert [sections] =
               Regex.run(~r/<nav\b[^>]*aria-label="Page sections"[^>]*>(.*?)<\/nav>/s, html, capture: :all_but_first)

      assert [[current_link]] = Regex.scan(~r/<a\b[^>]*aria-current="page"[^>]*>.*?<\/a>/s, sections)
      assert current_link =~ "<span>Podcast</span>"
      refute html =~ "Show unset fields"

      source_html = conn |> get(~p"/sources/#{source}?#{[tab: "source"]}") |> html_response(200)
      assert source_html =~ "Show unset fields"
    end

    test "defaults to the Videos tab and keeps the Source tab explicit", %{conn: conn} do
      source = source_fixture()

      default_html = conn |> get(~p"/sources/#{source}") |> html_response(200)
      assert active_page_section(default_html) =~ "<span>Videos</span>"

      source_html = conn |> get(~p"/sources/#{source}?#{[tab: "source"]}") |> html_response(200)
      assert active_page_section(source_html) =~ "<span>Source</span>"
    end

    test "renders source media statistics with mutually exclusive counts", %{conn: conn} do
      source = source_fixture()

      media_item_fixture(source_id: source.id)
      media_item_fixture(source_id: source.id)

      for _index <- 1..3 do
        media_item_fixture(source_id: source.id, media_filepath: nil)
      end

      media_item_fixture(source_id: source.id, media_filepath: nil, last_error: "Network is unreachable")

      media_item_fixture(
        source_id: source.id,
        media_filepath: nil,
        prevent_download: true,
        download_prevented_reason: :manual
      )

      media_item_fixture(source_id: source.id, media_filepath: nil, unavailable_at: DateTime.utc_now())

      response = conn |> get(~p"/sources/#{source}") |> html_response(200)

      assert response =~ ~s(aria-label="Downloaded: 2")
      assert response =~ ~s(aria-label="Pending: 3")
      assert response =~ ~s(aria-label="Failed: 1")
      assert response =~ ~s(aria-label="Prevented: 1")
      assert response =~ ~s(aria-label="Unavailable / Skipped: 1")
    end

    test "renders delayed download summary for manual playlists", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      conn = get(conn, ~p"/sources/#{source}")
      response = html_response(conn, 200)

      assert response =~ "Mode: Delayed"
      assert response =~ "Restore Automatic Downloads"
      assert response =~ "manual selection mode"
    end

    test "renders grouped source details instead of a raw attribute dump", %{conn: conn} do
      source = source_fixture(%{custom_name: "Library Details Source", description: "A channel description"})

      response = conn |> get(~p"/sources/#{source}?#{[tab: "source"]}") |> html_response(200)

      assert response =~ ~s(id="source-library-header")
      assert response =~ ~s(id="source-info-panel")
      assert response =~ "Identity"
      assert response =~ "Indexing"
      assert response =~ "Library Details Source"
      assert response =~ "A channel description"
      refute response =~ "Raw Attributes"
    end

    test "renders a blocking banner when downloads are disabled", %{conn: conn} do
      source = source_fixture(%{download_media: false})

      response = conn |> get(~p"/sources/#{source}") |> html_response(200)

      assert response =~ "index only"
      assert response =~ "never downloaded"
    end

    test "renders the podcast tab", %{conn: conn} do
      source = source_fixture()

      response = conn |> get(~p"/sources/#{source}?#{[tab: "podcast"]}") |> html_response(200)

      assert response =~ "RSS feed"
      assert response =~ "/sources/#{source.uuid}/feed"
    end

    test "shows the source status as a coloured pill in the header", %{conn: conn} do
      source = source_fixture(%{custom_name: "Header Source", download_media: false})
      disabled = source_fixture(%{custom_name: "Disabled Source", enabled: false})

      html = conn |> get(~p"/sources/#{source}") |> html_response(200)

      assert html =~ ~s(id="source-status-header-#{source.id}")
      assert html =~ ~s(data-source-status="Enabled, Download Media off")
      assert html =~ "theme-pill-info"

      html = conn |> get(~p"/sources/#{disabled}") |> html_response(200)
      assert html =~ ~s(data-source-status="Disabled")
      assert html =~ "theme-pill-warning"
    end

    test "uses the sources list's actions menu and delete dialog", %{conn: conn} do
      source = source_fixture(%{custom_name: "Dropdown Source"})
      media_item_fixture(source_id: source.id, media_filepath: nil)
      media_item_fixture(source_id: source.id)

      response = conn |> get(~p"/sources/#{source}") |> html_response(200)

      for label <-
            ["Copy RSS Feed", "Copy JSON", "Use as Template", "Download Pending", "Redownload Existing"] ++
              ["Force Index", "Refresh Metadata", "Sync Files on Disk", "Reconcile Files", "Start All"] do
        assert response =~ label
      end

      assert response =~ "Click again to start"
      refute response =~ "Start downloads for Dropdown Source?"
      refute response =~ "Are you sure"

      assert response =~ ~s(aria-label="Delete Dropdown Source")
      assert response =~ ~s(id="delete-source-modal")
      assert response =~ ~s(id="delete-source")
      assert response =~ ~s(action="/sources/#{source.id}")
      assert response =~ ~r/name="_method"[^>]*value="delete"/
      assert response =~ "Delete Source + Files"
    end

    test "hides Download Pending and Redownload Existing when there is nothing for them to do", %{conn: conn} do
      empty = source_fixture()
      paused = source_fixture(download_media: false)
      media_item_fixture(source_id: paused.id, media_filepath: nil)
      media_item_fixture(source_id: paused.id)

      for source <- [empty, paused] do
        response = conn |> get(~p"/sources/#{source}") |> html_response(200)

        refute response =~ "Download Pending"
        refute response =~ "Redownload Existing"
        assert response =~ "Force Index"
      end
    end

    test "copies the source JSON from a data attribute, not from script", %{conn: conn} do
      source = source_fixture(%{custom_name: "Name with ${alert(1)} and `ticks`"})

      response = conn |> get(~p"/sources/#{source}") |> html_response(200)

      refute response =~ "String.raw"
      assert response =~ "copyWithCallbacks($el.dataset.json"
      assert response =~ "data-json="
    end

    test "renders the videos tab label and normalizes downloaded alias", %{conn: conn} do
      source = source_fixture()

      conn_default = get(conn, ~p"/sources/#{source}")
      assert html_response(conn_default, 200) =~ "Videos"

      conn_videos = get(conn, ~p"/sources/#{source}?#{[tab: "videos"]}")
      assert html_response(conn_videos, 200) =~ "Videos"

      conn_alias = get(conn, ~p"/sources/#{source}?#{[tab: "downloaded"]}")
      assert html_response(conn_alias, 200) =~ "Videos"
    end

    test "renders the excluded tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Excluded"
    end

    test "renders the failed tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Failed"
    end

    test "renders the active tasks tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Active Tasks"
    end

    test "renders the job queue tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Job Queue"
    end

    test "renders the selection tab label for manual playlists", %{conn: conn} do
      source = source_fixture(collection_type: :playlist, selection_mode: :manual)

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Selection"
    end

    test "does not render the selection tab label for normal playlists", %{conn: conn} do
      source = source_fixture(collection_type: :playlist, selection_mode: :all)

      conn = get(conn, ~p"/sources/#{source}")

      refute html_response(conn, 200) =~ "Selection"
    end
  end

  describe "source row actions" do
    test "start_all enables the source and enqueues pending downloads", %{conn: conn} do
      source = source_fixture(%{enabled: false, download_media: false})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      conn = post(conn, ~p"/sources/#{source.id}/start_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Repo.reload!(source).enabled
      assert Repo.reload!(source).download_media
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "start_all reports when there is nothing to download", %{conn: conn} do
      source = source_fixture(%{enabled: false, download_media: false})

      conn = post(conn, ~p"/sources/#{source.id}/start_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Nothing to download for this source."
      refute Repo.reload!(source).enabled
      refute Repo.reload!(source).download_media
    end

    test "pause_all disables automatic downloads for the source", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      Pinchflat.Downloading.DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      conn = post(conn, ~p"/sources/#{source.id}/pause_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).download_media
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "pause_all cancels executing download tasks for the source", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "executing"])

      conn = post(conn, ~p"/sources/#{source.id}/pause_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).download_media
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
      assert Repo.get!(Oban.Job, task.job_id).state == "cancelled"
    end

    test "pause_all reports when there are no active downloads", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item_fixture(%{source_id: source.id, media_filepath: nil})

      conn = post(conn, ~p"/sources/#{source.id}/pause_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "No active downloads to pause for this source."
      assert Repo.reload!(source).download_media
    end

    test "stop_all disables the source and clears pending download jobs", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      Pinchflat.Downloading.DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      conn = post(conn, ~p"/sources/#{source.id}/stop_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).enabled
      refute Repo.reload!(source).download_media
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "stop_all cancels executing download tasks for the source", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "executing"])

      conn = post(conn, ~p"/sources/#{source.id}/stop_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).enabled
      refute Repo.reload!(source).download_media
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
      assert Repo.get!(Oban.Job, task.job_id).state == "cancelled"
    end

    for action <- [:pause_all, :stop_all] do
      test "#{action} cancels replacement work without touching other jobs or media", %{conn: conn} do
        source = source_fixture(%{enabled: true, download_media: true})
        item = media_item_with_attachments(%{source_id: source.id})
        original = File.read!(item.media_filepath)
        {:ok, replacement} = MediaDownloadWorker.kickoff_with_task(item, %{force: true})
        Repo.update_all(from(j in Oban.Job, where: j.id == ^replacement.job_id), set: [state: "executing"])

        other_item = media_item_fixture(%{media_filepath: nil})
        {:ok, other_task} = MediaDownloadWorker.kickoff_with_task(other_item)

        conn = post(conn, "/sources/#{source.id}/#{unquote(action)}", %{"return_to" => "/sources"})

        assert redirected_to(conn) == "/sources"
        refute Repo.reload!(source).download_media
        assert Repo.get!(Oban.Job, replacement.job_id).state == "cancelled"
        assert Repo.get!(Oban.Job, other_task.job_id).state == "available"
        assert File.read!(item.media_filepath) == original
        assert Repo.reload!(item).media_filepath == item.media_filepath
      end
    end

    test "stop_all reports when there is nothing to stop", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})

      conn = post(conn, ~p"/sources/#{source.id}/stop_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Nothing to stop for this source."
      assert Repo.reload!(source).enabled
      assert Repo.reload!(source).download_media
    end
  end

  describe "restore_automatic_downloads" do
    test "restores automatic downloads for a manual playlist source", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})

      conn = post(conn, ~p"/sources/#{source.id}/restore_automatic_downloads", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Repo.reload!(source).selection_mode == :all
      assert Repo.reload!(source).download_media
      refute Repo.reload!(media_item).prevent_download
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end
  end

  describe "apply_selection" do
    test "saves a manual playlist selection", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})
      selected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})
      unselected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: false})

      conn =
        post(conn, ~p"/sources/#{source}/apply_selection", %{
          "selected_media_ids" => [Integer.to_string(selected.id)],
          "selection_action" => "save"
        })

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "selection"]}"
      refute Repo.reload!(selected).prevent_download
      assert Repo.reload!(unselected).prevent_download
      refute Repo.reload!(source).download_media
    end

    test "download action enables downloads and enqueues selected items", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})
      selected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})
      _unselected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: false})

      conn =
        post(conn, ~p"/sources/#{source}/apply_selection", %{
          "selected_media_ids" => [Integer.to_string(selected.id)],
          "selection_action" => "download"
        })

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "selection"]}"
      assert Repo.reload!(source).download_media
      assert [%{args: %{"id" => selected_id}}] = all_enqueued(worker: MediaDownloadWorker)
      assert selected_id == selected.id
    end

    test "range input selects matching playlist indexes", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      first =
        media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true, playlist_index: 1})

      second =
        media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true, playlist_index: 2})

      third =
        media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true, playlist_index: 3})

      conn =
        post(conn, ~p"/sources/#{source}/apply_selection", %{
          "selection_range" => "1-2",
          "selection_action" => "save"
        })

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "selection"]}"
      refute Repo.reload!(first).prevent_download
      refute Repo.reload!(second).prevent_download
      assert Repo.reload!(third).prevent_download
    end
  end

  describe "force_redownload" do
    test "enqueues re-download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id, media_downloaded_at: now())

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_index" do
    test "forces an index", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "forces an index even if one wouldn't normally run", %{conn: conn} do
      source = source_fixture(index_frequency_minutes: 0, last_indexed_at: DateTime.utc_now())

      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args == %{"id" => source.id, "force" => true}
    end

    test "deletes pending indexing tasks", %{conn: conn} do
      source = source_fixture()
      {:ok, task} = MediaCollectionIndexingWorker.kickoff_with_task(source)
      job = Repo.preload(task, :job).job

      assert job.state == "available"
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert Repo.reload!(job).state == "cancelled"
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_index")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end

    test "returns to the sources list, naming the source, when started from it", %{conn: conn} do
      source = source_fixture(%{custom_name: "Listed Source"})

      listed = post(conn, ~p"/sources/#{source.id}/force_index", %{"return_to" => "/sources?type=videos"})
      assert redirected_to(listed) == ~p"/sources?type=videos"
      assert Phoenix.Flash.get(listed.assigns.flash, :info) == "Listed Source: Index enqueued."

      elsewhere = post(conn, ~p"/sources/#{source.id}/force_index", %{"return_to" => "https://example.com/"})
      assert redirected_to(elsewhere) == ~p"/sources"
    end
  end

  describe "force_metadata_refresh" do
    test "Refresh Metadata completes for a repaired legacy channel without changing user settings", %{conn: conn} do
      migration = Pinchflat.Repo.Migrations.RepairChannelCollectionTypes

      unless Code.ensure_loaded?(migration),
        do: Code.require_file("priv/repo/migrations/20261115010000_repair_channel_collection_types.exs")

      channel_id = "UCBR8-60-B28hp2BmDPdntcQ"
      profile = media_profile_fixture(download_source_images: true, download_nfo: true)
      directory = Path.join(Application.get_env(:pinchflat, :media_directory), "legacy-channel")
      image = Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "legacy-avatar.jpg")
      File.mkdir_p!(Path.dirname(image))
      File.cp!(Pinchflat.MediaFixtures.thumbnail_filepath_fixture(), image)

      source =
        source_fixture(
          collection_type: :playlist,
          collection_id: channel_id,
          original_url: "https://www.youtube.com/@YouTube",
          collection_name: "YouTube - Videos",
          custom_name: "My chosen name",
          custom_name_locked: true,
          description: "My chosen description",
          description_locked: true,
          media_profile_id: profile.id,
          download_media: false,
          series_directory: directory
        )

      item = Pinchflat.MediaFixtures.media_item_fixture(source_id: source.id)

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _template, _addl ->
          {:ok, source_details_return_fixture(%{filename: Path.join([directory, "Season 01", "video.mp4"])})}

        _url, :get_source_metadata, opts, _template, _addl ->
          metadata =
            Jason.encode!(%{
              id: channel_id,
              title: "YouTube",
              channel: "YouTube",
              description: "Remote description",
              thumbnails: [%{id: "avatar_uncropped", filepath: image}]
            })

          # Reproduce the nested playlist output unless the migrated source uses channel options.
          {:ok, if(opts[:playlist_items] == 0, do: metadata, else: metadata <> "\n" <> metadata)}
      end)

      Ecto.Migration.Runner.run(Repo, Repo.config(), 20_261_115_010_000, migration, :forward, :up, :up, log: false)
      response = post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert redirected_to(response) == ~p"/sources/#{source.id}"
      assert [job] = all_enqueued(worker: SourceMetadataStorageWorker)
      assert :ok = perform_job(SourceMetadataStorageWorker, job.args)
      updated = Repo.preload(Repo.reload!(source), :metadata)

      assert updated.collection_type == :channel
      assert updated.collection_id == channel_id
      assert updated.uuid == source.uuid
      assert updated.custom_name == "My chosen name"
      assert updated.description == "My chosen description"
      refute updated.download_media
      assert updated.series_directory == directory
      assert Repo.reload!(item).source_id == source.id
      assert File.exists?(updated.metadata.metadata_filepath)
      assert File.exists?(updated.metadata.poster_filepath)
      assert File.exists?(updated.poster_filepath)
      assert File.exists?(updated.nfo_filepath)
      assert updated.nfo_filepath == Path.join(directory, "tvshow.nfo")
      assert File.read!(updated.poster_filepath) == File.read!(image)
    end

    test "forces a metadata refresh", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
      post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert [_] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "sync_files_on_disk" do
    test "forces a file sync", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: FileSyncingWorker)
      post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert [_] = all_enqueued(worker: FileSyncingWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  test "S02: CSRF token validation rejects forged tokens" do
    conn = build_conn()
    Plug.CSRFProtection.load_state(conn.secret_key_base, nil)
    masked_token = Plug.CSRFProtection.get_csrf_token()
    session_token = Plug.CSRFProtection.dump_state()

    assert Plug.CSRFProtection.valid_state_and_csrf_token?(session_token, masked_token)
    refute Plug.CSRFProtection.valid_state_and_csrf_token?(session_token, "forged-token")
  end

  defp active_page_section(html) do
    assert [sections] =
             Regex.run(~r/<nav\b[^>]*aria-label="Page sections"[^>]*>(.*?)<\/nav>/s, html, capture: :all_but_first)

    assert [[current_link]] = Regex.scan(~r/<a\b[^>]*aria-current="page"[^>]*>.*?<\/a>/s, sections)
    current_link
  end

  defp create_source(_) do
    source = source_fixture()
    media_item = media_item_with_attachments(%{source_id: source.id})

    %{source: source, media_item: media_item}
  end

  defp runner_function_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {
      :ok,
      Phoenix.json_library().encode!(%{
        channel: "some channel name",
        channel_id: "some_channel_id_#{:rand.uniform(1_000_000)}",
        playlist_id: "some_playlist_id_#{:rand.uniform(1_000_000)}",
        playlist_title: "some playlist name"
      })
    }
  end

  describe "saved title filters" do
    test "lists, saves and deletes saved filters", %{conn: conn} do
      assert %{"filters" => []} = conn |> get(~p"/sources/title_filters") |> json_response(200)

      response =
        conn
        |> post(~p"/sources/title_filters", %{"name" => "No shorts", "regex" => "(?i)^(?!.*shorts).*$"})
        |> json_response(200)

      assert %{"filter" => %{"id" => id, "name" => "No shorts"}, "filters" => [%{"id" => id}]} = response

      assert %{"filters" => [%{"regex" => "(?i)^(?!.*shorts).*$"}]} =
               conn |> get(~p"/sources/title_filters") |> json_response(200)

      assert %{"filters" => []} = conn |> delete(~p"/sources/title_filters/#{id}") |> json_response(200)
    end

    test "does not let a new stored filter take an existing name", %{conn: conn} do
      conn |> post(~p"/sources/title_filters", %{"name" => "Music", "regex" => "(?i)music"}) |> json_response(200)

      response =
        conn
        |> post(~p"/sources/title_filters", %{"name" => "Music", "regex" => "(?i)live"})
        |> json_response(422)

      assert response["error"] =~ "Name is already used by another stored filter"
      assert %{"filters" => [%{"regex" => "(?i)music"}]} = conn |> get(~p"/sources/title_filters") |> json_response(200)
    end

    test "updates the regex of a stored filter by id", %{conn: conn} do
      %{"filter" => %{"id" => id}} =
        conn |> post(~p"/sources/title_filters", %{"name" => "Music", "regex" => "(?i)music"}) |> json_response(200)

      assert %{"filter" => %{"id" => ^id, "name" => "Music", "regex" => "(?i)live"}} =
               conn |> put(~p"/sources/title_filters/#{id}", %{"regex" => "(?i)live"}) |> json_response(200)

      assert %{"error" => "That stored filter no longer exists."} =
               conn |> put(~p"/sources/title_filters/#{id + 1}", %{"regex" => "x"}) |> json_response(404)
    end

    test "explains why a filter could not be saved", %{conn: conn} do
      response =
        conn
        |> post(~p"/sources/title_filters", %{"name" => "Broken", "regex" => "(unclosed"})
        |> json_response(422)

      assert response["error"] =~ "Regex is not a regex the database can use"
    end

    test "reports a saved filter that no longer exists", %{conn: conn} do
      assert %{"error" => "That stored filter no longer exists.", "filters" => []} =
               conn |> delete(~p"/sources/title_filters/999999") |> json_response(404)

      assert %{"error" => _} = conn |> delete(~p"/sources/title_filters/not-a-number") |> json_response(404)
    end

    test "renders stored filters above the word lists and the save bar below the tester", %{conn: conn} do
      response = conn |> get(~p"/sources/new") |> html_response(200)

      assert response =~ "pinchflatSavedTitleFilters()"
      assert response =~ "Stored Filters"
      assert response =~ "Commonly used filters can be stored for access across all sources"
      refute response =~ "not required"
      assert position(response, "data-saved-title-filters") < position(response, ~s(data-title-filter-list="any"))
      assert position(response, "Test this filter") < position(response, "data-title-filter-save-bar")
      assert response =~ ~s|x-show="showSaveBar()"|
    end
  end

  defp position(response, text) do
    {index, _length} = :binary.match(response, text)
    index
  end

  defp create_cullable_items(source, count) do
    for offset <- 0..(count - 1) do
      media_item_fixture(%{
        source_id: source.id,
        media_filepath: "/video/#{offset}.mp4",
        uploaded_at: DateTime.add(~U[2026-11-20 00:00:00Z], offset, :day)
      })
    end
  end
end
