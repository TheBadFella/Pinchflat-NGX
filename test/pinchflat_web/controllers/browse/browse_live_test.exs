defmodule PinchflatWeb.Browse.BrowseLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task
  alias PinchflatWeb.Browse.BrowseLive

  @mock_videos [
    %{
      id: "vid_test_123",
      url: "https://www.youtube.com/watch?v=vid_test_123",
      title: "Elixir Phoenix LiveView Guide",
      channel_id: "UC_elixir_channel",
      channel_title: "Elixir Creators",
      duration: 360,
      upload_date: "20261001",
      thumbnail: "https://example.com/thumb1.jpg",
      view_count: 1500
    },
    %{
      id: "vid_test_456",
      url: "https://www.youtube.com/watch?v=vid_test_456",
      title: "Advanced Tailwind CSS",
      channel_id: "UC_tailwind_channel",
      channel_title: "CSS Masters",
      duration: 725,
      upload_date: "20261002",
      thumbnail: "https://example.com/thumb2.jpg",
      view_count: 2400
    }
  ]

  @mock_channels [
    %{
      id: "UC_elixir_channel",
      url: "https://www.youtube.com/channel/UC_elixir_channel",
      title: "Elixir Creators",
      handle: "@elixir_creators",
      thumbnail: "https://example.com/channel_thumb.jpg",
      subscriber_count: 50_000
    }
  ]

  setup :set_mox_global

  test "restores URL search state in the controller-rendered LiveView", %{conn: conn} do
    profile = media_profile_fixture()
    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "restored query", _opts -> {:ok, @mock_videos} end)
    {:ok, view, _} = live_isolated(conn, BrowseLive)

    render_hook(view, "restore_search", %{
      "q" => "restored query",
      "tab" => "videos",
      "profile" => to_string(profile.id)
    })

    assert render_async(view) =~ "Elixir Phoenix LiveView Guide"
    assert has_element?(view, "#browse_query[value='restored query']")
    assert has_element?(view, "#profile_selector_form[phx-auto-recover='ignore']")
  end

  test "restores Unicode queries within the search input character limit", %{conn: conn} do
    profile = media_profile_fixture()
    query = String.duplicate("検索", 60)
    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn ^query, _opts -> {:ok, @mock_videos} end)
    {:ok, view, _} = live_isolated(conn, BrowseLive)

    render_hook(view, "restore_search", %{"q" => query, "profile" => to_string(profile.id)})

    assert render_async(view) =~ "Elixir Phoenix LiveView Guide"
    assert has_element?(view, "#browse_query[value='#{query}']")

    render_hook(view, "restore_search", %{"q" => String.duplicate("a", 201)})
    assert has_element?(view, "#browse_query[value='#{query}']")
  end

  test "keeps previous results inert and refuses stale download actions while searching", %{conn: conn} do
    media_profile_fixture()
    caller = self()
    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "first", _opts -> {:ok, @mock_videos} end)

    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "second", _opts ->
      send(caller, {:search_waiting, self()})

      receive do
        :finish_search -> {:ok, []}
      after
        5000 -> {:error, :timeout}
      end
    end)

    {:ok, view, _} = live_isolated(conn, BrowseLive)
    view |> form("#browse_search_form", %{"query" => "first"}) |> render_submit()
    assert render_async(view) =~ "Elixir Phoenix LiveView Guide"

    view |> form("#browse_search_form", %{"query" => "second"}) |> render_submit()
    assert_receive {:search_waiting, provider}
    assert has_element?(view, "#browse-results[inert][aria-busy='true']", "Elixir Phoenix LiveView Guide")
    render_hook(view, "download_video", %{"id" => "vid_test_123"})
    assert Repo.aggregate(Source, :count) == 0
    send(provider, :finish_search)
    refute render_async(view) =~ "Elixir Phoenix LiveView Guide"
  end

  test "bookmarklet opens a preview without creating sources or jobs", %{conn: conn} do
    media_profile_fixture()
    before_counts = {Repo.aggregate(Source, :count), Repo.aggregate(Oban.Job, :count)}
    html = conn |> get(~p"/browse?url=https://youtu.be/dQw4w9WgXcQ") |> html_response(200)
    assert html =~ "https://youtu.be/dQw4w9WgXcQ"
    assert html =~ "paste_url_resolve_button"
    assert {Repo.aggregate(Source, :count), Repo.aggregate(Oban.Job, :count)} == before_counts
  end

  test "browse keeps the application sidebar and header", %{conn: conn} do
    media_profile_fixture()
    html = conn |> get(~p"/browse") |> html_response(200)
    assert html =~ "theme-sidebar-list"
    assert html =~ "Browse YouTube"
    assert html =~ "theme-app-shell"
  end

  describe "mount and initial state" do
    test "renders page header, search controls, and profile dropdown", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Default Profile"})

      {:ok, _view, html} = live_isolated(conn, BrowseLive, session: %{})

      assert html =~ "Browse YouTube"
      assert html =~ "Search YouTube videos or channels"
      assert html =~ profile.name
      assert html =~ "Videos"
      assert html =~ "Channels"
    end
  end

  describe "video search and B03 read-only guarantees" do
    test "searches videos and renders cards with library status badges", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Test Profile"})

      # Create one local media item matching vid_test_123
      tmp_dir = Application.fetch_env!(:pinchflat, :media_directory)
      file_path = Path.join(tmp_dir, "vid_test_123_#{System.unique_integer([:positive])}.mp4")
      File.write!(file_path, "local video")

      source = source_fixture(%{media_profile_id: profile.id})

      _media_item =
        media_item_fixture(%{
          media_id: "vid_test_123",
          source_id: source.id,
          media_filepath: file_path
        })

      Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "elixir", _opts ->
        {:ok, @mock_videos}
      end)

      # Record record counts before search
      source_count_before = Repo.aggregate(Source, :count, :id)
      media_count_before = Repo.aggregate(MediaItem, :count, :id)
      task_count_before = Repo.aggregate(Task, :count, :id)
      job_count_before = Repo.aggregate(Oban.Job, :count, :id)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      view
      |> form("#browse_search_form", %{"query" => "elixir"})
      |> render_submit()

      rendered = render_async(view)

      # Assert card rendering
      assert rendered =~ "Elixir Phoenix LiveView Guide"
      assert rendered =~ "Advanced Tailwind CSS"
      assert rendered =~ "In library"
      assert rendered =~ "Not in library"
      assert rendered =~ "Open"
      assert rendered =~ "Download"

      # B03: Zero DB rows or background jobs created by browse search!
      assert Repo.aggregate(Source, :count, :id) == source_count_before
      assert Repo.aggregate(MediaItem, :count, :id) == media_count_before
      assert Repo.aggregate(Task, :count, :id) == task_count_before
      assert Repo.aggregate(Oban.Job, :count, :id) == job_count_before

      File.rm(file_path)
    end
  end

  describe "channel search and bounded channel preview" do
    test "searches channels and opens bounded preview of 25 videos", %{conn: conn} do
      _profile = media_profile_fixture()

      Mox.expect(YoutubeBrowserProviderMock, :search_channels, fn "creators", _opts ->
        {:ok, @mock_channels}
      end)

      Mox.expect(YoutubeBrowserProviderMock, :get_channel_preview, fn "UC_elixir_channel", _opts ->
        {:ok, @mock_videos}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      # Switch to channels tab
      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='channels']")
      |> render_click()

      # Submit search
      view
      |> form("#browse_search_form", %{"query" => "creators"})
      |> render_submit()

      rendered_channels = render_async(view)
      assert rendered_channels =~ "Elixir Creators"
      assert rendered_channels =~ "@elixir_creators"
      assert rendered_channels =~ "Preview Videos"
      assert rendered_channels =~ "Subscribe"

      # Click Preview Videos
      view
      |> element("button[phx-click='view_channel_preview']", "Preview Videos")
      |> render_click()

      preview_html = render_async(view)
      assert preview_html =~ "Channel Preview"
      assert preview_html =~ "Displaying the first 25 recent videos"
      assert preview_html =~ "Elixir Phoenix LiveView Guide"

      # Close preview
      view
      |> element("button[phx-click='close_channel_preview']")
      |> render_click()

      refute render(view) =~ "Channel Preview"
    end
  end

  describe "video details panel" do
    test "fetches canonical details and displays copy breakdown", %{conn: conn} do
      _profile = media_profile_fixture()

      detail_data = %{
        id: "vid_test_123",
        url: "https://www.youtube.com/watch?v=vid_test_123",
        title: "Elixir Phoenix LiveView Guide Detailed",
        description: "Full detailed description of LiveView architecture.",
        channel_id: "UC_elixir_channel",
        channel_title: "Elixir Creators",
        duration: 360,
        upload_date: "20261001",
        thumbnails: [%{"url" => "https://example.com/detail_thumb.jpg", "width" => 640}],
        thumbnail: "https://example.com/detail_thumb.jpg",
        view_count: 5000
      }

      Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "detailed", _opts ->
        {:ok, @mock_videos}
      end)

      Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn "vid_test_123", _opts ->
        {:ok, detail_data}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      view
      |> form("#browse_search_form", %{"query" => "detailed"})
      |> render_submit()

      render_async(view)

      view
      |> element("button[phx-click='view_video_details'][phx-value-id='vid_test_123']")
      |> render_click()

      details_html = render_async(view)
      assert details_html =~ "Video Details"
      assert details_html =~ "Full detailed description of LiveView architecture."

      # Close details
      view
      |> element("button[phx-click='close_video_details']")
      |> render_click()

      refute render(view) =~ "Full detailed description of LiveView architecture."
    end
  end

  describe "profile switching" do
    test "re-evaluates library status when profile selection changes", %{conn: conn} do
      profile_a = media_profile_fixture(%{name: "Profile Alpha"})
      profile_b = media_profile_fixture(%{name: "Profile Beta"})

      source_b = source_fixture(%{media_profile_id: profile_b.id, custom_name: "Source Beta"})

      _item_b =
        media_item_fixture(%{
          media_id: "vid_test_123",
          source_id: source_b.id,
          media_filepath: nil
        })

      Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "profile_test", _opts ->
        {:ok, @mock_videos}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      # With 2 profiles, explicit selection is required (R216-8)
      view
      |> form("#profile_selector_form", %{"profile_id" => to_string(profile_a.id)})
      |> render_change()

      view
      |> form("#browse_search_form", %{"query" => "profile_test"})
      |> render_submit()

      # Under Profile Alpha, it shows "In other profile"
      html_alpha = render_async(view)
      assert html_alpha =~ "In other profile (Profile Beta)"

      # Switch to Profile Beta
      view
      |> form("#profile_selector_form", %{"profile_id" => to_string(profile_b.id)})
      |> render_change()

      # Now under Profile Beta, it shows "Indexed"
      html_beta = render(view)
      assert html_beta =~ "Indexed"
    end
  end

  describe "single-video download intake" do
    test "queues download for a video and updates flash and source", %{conn: conn} do
      profile = media_profile_fixture()

      Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "download_test", _opts ->
        {:ok, @mock_videos}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      view
      |> form("#browse_search_form", %{"query" => "download_test"})
      |> render_submit()

      render_async(view)

      download_btn = element(view, "button[phx-click='download_video'][phx-value-id='vid_test_123']")
      rendered = render_click(download_btn)

      assert rendered =~ "Single-video source created" or rendered =~ "Queued"
      source = Repo.get_by!(Source, collection_id: "vid_test_123", media_profile_id: profile.id)
      stub(AppriseRunnerMock, :run, fn _, _ -> {:ok, ""} end)

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_media_attributes_for_collection, _opts, _template, _extra ->
          {:ok,
           Jason.encode!(%{
             "id" => "vid_test_123",
             "title" => "Indexed Browse title",
             "original_url" => source.original_url,
             "upload_date" => "20261019",
             "duration" => 600,
             "filename" => "/tmp/test/media/Indexed Browse title.mp4"
           })}

        _url, :predict_filepath_from_metadata, _opts, _template, _extra ->
          {:ok, Jason.encode!(%{"filename" => "/tmp/test/media/Indexed Browse title.mp4"})}
      end)

      assert :ok = perform_job(Pinchflat.SlowIndexing.MediaCollectionIndexingWorker, %{id: source.id})
      assert Repo.reload!(source).custom_name == "Indexed Browse title"
    end
  end

  describe "explicit channel subscription" do
    test "B18: prompts with confirmation modal and creates source on confirm", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Test Profile"})

      Mox.expect(YoutubeBrowserProviderMock, :search_channels, fn "creators_sub", _opts ->
        {:ok, @mock_channels}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      # Switch to channels tab
      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='channels']")
      |> render_click()

      # Submit search
      view
      |> form("#browse_search_form", %{"query" => "creators_sub"})
      |> render_submit()

      render_async(view)

      # Click Subscribe
      view
      |> element("button[phx-click*='prompt_subscribe_channel']", "Subscribe")
      |> render_click()

      # Confirmation dialog is now rendered!
      modal_html = render(view)
      assert modal_html =~ "Channel Subscription"
      assert modal_html =~ "Elixir Creators"
      assert modal_html =~ profile.name
      assert modal_html =~ "Confirm Subscription"
      assert modal_html =~ "Cancel"

      # Click Cancel first to verify dismissal
      view
      |> element("button[phx-click*='cancel_subscribe_channel']", "Cancel")
      |> render_click()

      refute render(view) =~ "Channel Subscription"
      assert Repo.get_by(Source, collection_id: "UC_elixir_channel", media_profile_id: profile.id) == nil

      # Re-prompt and verify Escape key dismissal
      view
      |> element("button[phx-click*='prompt_subscribe_channel']", "Subscribe")
      |> render_click()

      assert render(view) =~ "Channel Subscription"

      view
      |> element("#confirm-subscribe-dialog")
      |> render_keydown(%{"key" => "Escape"})

      refute render(view) =~ "Channel Subscription"

      # Re-prompt and confirm
      view
      |> element("button[phx-click*='prompt_subscribe_channel']", "Subscribe")
      |> render_click()

      confirmed_html =
        view
        |> element("button[phx-click*='confirm_subscribe_channel']")
        |> render_click()

      assert confirmed_html =~ "Subscribed"
      assert confirmed_html =~ "Open Source"

      # Verify source in database
      created = Repo.get_by(Source, collection_id: "UC_elixir_channel", media_profile_id: profile.id)
      assert created != nil
      assert created.collection_type == :channel
      assert created.custom_name == "Elixir Creators"
    end
  end

  describe "live PubSub status updates and responsive interaction" do
    test "B19: coalesces rapid PubSub broadcasts and dynamically updates card state to In library when media exists", %{
      conn: conn
    } do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id})

      # Initially no media item
      Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "pubsub_test", _opts ->
        {:ok, @mock_videos}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      view
      |> form("#browse_search_form", %{"query" => "pubsub_test"})
      |> render_submit()

      initial_html = render_async(view)
      assert initial_html =~ "Not in library"
      refute initial_html =~ "In library"

      # Create local media item with real file on disk
      tmp_dir = Application.fetch_env!(:pinchflat, :media_directory)
      file_path = Path.join(tmp_dir, "vid_pubsub_#{System.unique_integer([:positive])}.mp4")
      File.write!(file_path, "downloaded video bytes")

      media_item =
        media_item_fixture(%{
          media_id: "vid_test_123",
          source_id: source.id,
          media_filepath: file_path
        })

      # Simulate duplicate event burst from background worker
      PinchflatWeb.Endpoint.broadcast("job:state", "change", %{job_id: 1})
      PinchflatWeb.Endpoint.broadcast("job:progress", "update", %{job_id: 1, progress: 50})
      PinchflatWeb.Endpoint.broadcast("job:state", "change", %{job_id: 1})

      # Trigger coalesced refresh
      send(view.pid, :coalesced_status_refresh)

      updated_html = render(view)
      assert updated_html =~ "In library"
      assert updated_html =~ "/sources/#{source.id}/media/#{media_item.id}"

      File.rm(file_path)
    end

    test "switching tabs while search is in-flight invalidates old results and avoids template crash", %{
      conn: conn
    } do
      media_profile_fixture(%{name: "Tab Switch Profile"})
      owner = self()

      Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn "delayed_search", _opts ->
        send(owner, {:search_started, self()})

        receive do
          :release_search -> {:ok, @mock_videos}
        end
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      view
      |> form("#browse_search_form", %{"query" => "delayed_search", "tab" => "videos"})
      |> render_submit()

      assert_receive {:search_started, provider_pid}, 2000

      # User switches tab to channels while search is in flight
      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='channels']")
      |> render_click()

      # Release search provider
      send(provider_pid, :release_search)

      # View must render without crashing on KeyError :handle
      html = render_async(view)
      assert is_binary(html)
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_tab == :channels
      refute Enum.any?(assigns.results, &Map.has_key?(&1, :channel_title))
    end

    test "delayed video details re-enrich against currently selected profile", %{conn: conn} do
      first = media_profile_fixture(%{name: "First Profile"})
      second = media_profile_fixture(%{name: "Second Profile"})
      owner = self()

      detail = %{
        id: "vid_test_123",
        title: "Delayed Detail",
        thumbnail: nil,
        url: "https://www.youtube.com/watch?v=vid_test_123",
        description: "Test",
        channel_id: "UC_elixir_channel",
        channel_title: "Elixir Creators",
        duration: 360,
        view_count: 100,
        upload_date: "20261001"
      }

      Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn "vid_test_123", _opts ->
        send(owner, {:detail_started, self()})

        receive do
          :release_detail -> {:ok, detail}
        end
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
      render_change(view, "select_profile", %{profile_id: to_string(first.id)})
      render_click(view, "view_video_details", %{id: detail.id})

      assert_receive {:detail_started, provider_pid}, 2000

      # Change profile while detail request is in-flight
      render_change(view, "select_profile", %{profile_id: to_string(second.id)})
      send(provider_pid, :release_detail)

      render_async(view)
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_profile_id == second.id

      assert is_nil(assigns.selected_video_detail) or
               assigns.selected_video_detail.status.selected_profile_id == second.id
    end
  end

  test "pending search uses the profile selected before its reply", %{conn: conn} do
    first = media_profile_fixture(%{name: "First"})
    second = media_profile_fixture(%{name: "Second"})
    parent = self()

    Mox.expect(YoutubeBrowserProviderMock, :search_videos, fn _query, _opts ->
      send(parent, {:search_waiting, self()})

      receive do
        :continue -> {:ok, @mock_videos}
      end
    end)

    {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
    render_change(view, "select_profile", %{"profile_id" => to_string(first.id)})
    view |> form("#browse_search_form", %{"query" => "Elixir"}) |> render_submit()
    assert_receive {:search_waiting, provider}, 2000
    render_change(view, "select_profile", %{"profile_id" => to_string(second.id)})
    send(provider, :continue)
    render_async(view)

    assert Enum.all?(:sys.get_state(view.pid).socket.assigns.results, fn result ->
             result.status.selected_profile_id == second.id
           end)

    assert length(:sys.get_state(view.pid).socket.assigns.results) == 2
  end

  describe "CV01 - Pasted single-video URL modal and intake" do
    test "opens and closes paste url dialog with focus trap elements", %{conn: conn} do
      _profile = media_profile_fixture(%{name: "Single Profile"})

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})

      # Initially dialog is not present
      refute has_element?(view, "#paste-url-dialog")

      # Open modal
      view |> element("#open-paste-url-button") |> render_click()
      assert has_element?(view, "#paste-url-dialog")
      assert has_element?(view, "#paste_url_input")
      assert has_element?(view, "#paste_url_resolve_button")

      # Close modal via cancel button
      view |> element("#paste-cancel-button") |> render_click()
      refute has_element?(view, "#paste-url-dialog")

      # Re-open and close via close 'X' button
      view |> element("#open-paste-url-button") |> render_click()
      assert has_element?(view, "#paste-url-dialog")
      view |> element("#close-paste-url-button") |> render_click()
      refute has_element?(view, "#paste-url-dialog")
    end

    test "rejects invalid or unsupported URLs with friendly error", %{conn: conn} do
      _profile = media_profile_fixture(%{name: "Test Profile"})

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
      view |> element("#open-paste-url-button") |> render_click()

      # Submit invalid host
      view
      |> form("#paste_url_form", %{"url" => "https://vimeo.com/123456789"})
      |> render_submit()

      assert has_element?(view, "#paste-url-error")
      assert render(view) =~ "Please enter a valid YouTube URL"

      # Submit playlist URL
      view
      |> form("#paste_url_form", %{"url" => "https://www.youtube.com/playlist?list=PL12345"})
      |> render_submit()

      assert has_element?(view, "#paste-url-error")
      assert render(view) =~ "subscription workflow"
    end

    test "resolves valid URL with zero database writes and renders preview", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Preview Profile"})
      test_video_id = "dQw4w9WgXcQ"

      mock_detail = %{
        id: test_video_id,
        title: "Never Gonna Give You Up",
        url: "https://www.youtube.com/watch?v=#{test_video_id}",
        description: "Classic video",
        channel_id: "UCuAXFkgsw1L7xaCfnd5JJOw",
        channel_title: "Rick Astley",
        duration: 213,
        view_count: 1_500_000_000,
        upload_date: "20091025",
        thumbnail: "https://example.com/rick.jpg"
      }

      Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn ^test_video_id, _opts ->
        {:ok, mock_detail}
      end)

      # Record DB counts before resolution
      source_count_before = Repo.aggregate(Source, :count, :id)
      media_count_before = Repo.aggregate(MediaItem, :count, :id)
      task_count_before = Repo.aggregate(Task, :count, :id)
      job_count_before = Repo.aggregate(Oban.Job, :count, :id)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
      view |> element("#open-paste-url-button") |> render_click()
      render_change(view, "select_paste_profile", %{"profile_id" => to_string(profile.id)})

      # Resolve URL
      view
      |> form("#paste_url_form", %{"url" => "https://www.youtube.com/watch?v=#{test_video_id}"})
      |> render_submit()

      render_async(view)

      # Verify preview is rendered
      assert has_element?(view, "#paste-resolved-preview")
      html = render(view)
      assert html =~ "Never Gonna Give You Up"
      assert html =~ "Rick Astley"
      assert html =~ "03:33"
      assert html =~ "Not in library"
      assert has_element?(view, "#paste-download-button")

      # Prove ZERO database records were created during resolution
      assert Repo.aggregate(Source, :count, :id) == source_count_before
      assert Repo.aggregate(MediaItem, :count, :id) == media_count_before
      assert Repo.aggregate(Task, :count, :id) == task_count_before
      assert Repo.aggregate(Oban.Job, :count, :id) == job_count_before
    end

    test "downloads resolved video through guarded intake", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Download Profile"})
      test_video_id = "dQw4w9WgXcQ"

      mock_detail = %{
        id: test_video_id,
        title: "Never Gonna Give You Up",
        url: "https://www.youtube.com/watch?v=#{test_video_id}",
        description: "Classic video",
        channel_id: "UCuAXFkgsw1L7xaCfnd5JJOw",
        channel_title: "Rick Astley",
        duration: 213,
        duration_string: "03:33",
        view_count: 1_500_000_000,
        upload_date: "20091025",
        thumbnail: "https://example.com/rick.jpg"
      }

      Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn ^test_video_id, _opts ->
        {:ok, mock_detail}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
      view |> element("#open-paste-url-button") |> render_click()
      render_change(view, "select_paste_profile", %{"profile_id" => to_string(profile.id)})

      view
      |> form("#paste_url_form", %{"url" => "https://youtu.be/#{test_video_id}"})
      |> render_submit()

      render_async(view)
      assert has_element?(view, "#paste-download-button")

      # Click download
      _click_html = view |> element("#paste-download-button") |> render_click()

      # Modal should be closed, flash should be set
      refute has_element?(view, "#paste-url-dialog")
      flash = :sys.get_state(view.pid).socket.assigns.flash
      assert flash["info"] =~ "Video download queued" or flash["info"] =~ "Single-video source created"

      # Single-video source must now exist in DB
      source = Repo.get_by(Source, collection_id: test_video_id, media_profile_id: profile.id)
      assert source != nil
    end

    test "shows Open in Library when video is already present", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Present Profile"})
      test_video_id = "dQw4w9WgXcQ"

      # Create local media item
      tmp_dir = Application.fetch_env!(:pinchflat, :media_directory)
      file_path = Path.join(tmp_dir, "test_rick_#{System.unique_integer([:positive])}.mp4")
      File.write!(file_path, "rickroll")

      source = source_fixture(%{media_profile_id: profile.id})

      media_item =
        media_item_fixture(%{
          media_id: test_video_id,
          source_id: source.id,
          media_filepath: file_path
        })

      mock_detail = %{
        id: test_video_id,
        title: "Never Gonna Give You Up",
        url: "https://www.youtube.com/watch?v=#{test_video_id}",
        description: "Classic video",
        channel_id: "UCuAXFkgsw1L7xaCfnd5JJOw",
        channel_title: "Rick Astley",
        duration: 213,
        duration_string: "03:33",
        view_count: 1_500_000_000,
        upload_date: "20091025",
        thumbnail: "https://example.com/rick.jpg"
      }

      Mox.expect(YoutubeBrowserProviderMock, :get_video_details, fn ^test_video_id, _opts ->
        {:ok, mock_detail}
      end)

      {:ok, view, _html} = live_isolated(conn, BrowseLive, session: %{})
      view |> element("#open-paste-url-button") |> render_click()
      render_change(view, "select_paste_profile", %{"profile_id" => to_string(profile.id)})

      view
      |> form("#paste_url_form", %{"url" => "https://www.youtube.com/watch?v=#{test_video_id}"})
      |> render_submit()

      render_async(view)

      # Should show In library and Open in Library link, NO download button
      html = render(view)
      assert html =~ "In library"
      assert html =~ "Open in Library"
      assert html =~ "/sources/#{source.id}/media/#{media_item.id}"
      refute has_element?(view, "#paste-download-button")

      File.rm(file_path)
    end
  end
end
