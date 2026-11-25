defmodule PinchflatWeb.Sources.SourceLive.IndexTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Sources.Source
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive

  describe "source categories" do
    test "separates individual videos from channels and playlists", %{conn: conn} do
      channel = source_fixture(custom_name: "Subscribed channel")
      playlist = source_fixture(custom_name: "Saved playlist", collection_type: :playlist)
      video = source_fixture(custom_name: "Pasted video", collection_type: :video)

      {:ok, _view, html} = live_isolated(conn, IndexTableLive, session: create_session())
      assert html =~ channel.custom_name
      assert html =~ playlist.custom_name
      refute html =~ video.custom_name

      session = Map.put(create_session(), "source_type", "videos")
      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: session)
      assert html =~ video.custom_name
      refute html =~ channel.custom_name
      refute html =~ playlist.custom_name
      assert render_click(view, "view_change", %{"view" => "grid"}) =~ video.custom_name
    end

    test "paginates and refreshes only individual videos", %{conn: conn} do
      source_fixture(custom_name: "A channel")
      first = source_fixture(custom_name: "First video", collection_type: :video)
      second = source_fixture(custom_name: "Second video", collection_type: :video)
      session = Map.merge(create_session(), %{"source_type" => "videos", "results_per_page" => 1})
      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: session)
      assert html =~ first.custom_name
      refute html =~ second.custom_name

      click_element(view, "button.pagination-next")
      assert render(view) =~ second.custom_name
      refute render(view) =~ first.custom_name
      media_item_fixture(source_id: second.id)
      send(view.pid, :throttled_refresh)
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(6)") == "1"
      refute render(view) =~ "A channel"
      assert has_element?(view, "input[name='return_to'][value='/sources?type=videos']")
    end

    test "explains an empty individual videos list", %{conn: conn} do
      source_fixture()
      session = Map.put(create_session(), "source_type", "videos")
      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: session)
      assert html =~ "No individual videos yet"
      assert has_element?(view, "a[href='/browse']", "Browse YouTube")
      refute has_element?(view, "#source-table")
    end

    test "leaves out the table header when a tab has no sources", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      assert has_element?(view, "h3", "No channels or playlists yet")
      refute has_element?(view, "#source-table")
      refute has_element?(view, "th")
    end
  end

  describe "initial rendering" do
    test "shows effective retention and its origin in table and grid views", %{conn: conn} do
      profile = media_profile_fixture(%{retention_period_days: 30})
      source_fixture(custom_name: "Inheriting source", media_profile_id: profile.id)
      source_fixture(custom_name: "Disabled retention", media_profile_id: profile.id, retention_period_days: 0)
      source_fixture(custom_name: "Explicit retention", media_profile_id: profile.id, retention_period_days: 1)

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert html =~ "30 days (profile default)"
      assert html =~ "No age-based cleanup (source override)"
      assert html =~ "1 day (source override)"

      grid = render_click(view, "view_change", %{"view" => "grid"})
      assert grid =~ "30 days (profile default)"
      assert grid =~ "No age-based cleanup (source override)"
      assert grid =~ "1 day (source override)"
    end

    test "lists all sources", %{conn: conn} do
      source = source_fixture()

      {:ok, _view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert html =~ source.custom_name
    end

    test "lists sources that have stored metadata", %{conn: conn} do
      source = source_with_metadata(%{custom_name: "Indexed Source"})

      {:ok, _view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert html =~ source.custom_name
    end

    test "omits sources that have marked_for_deletion_at set", %{conn: conn} do
      source = source_fixture(marked_for_deletion_at: DateTime.utc_now())

      {:ok, _view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      refute html =~ source.custom_name
    end

    test "omits sources who's media profile has marked_for_deletion_at set", %{conn: conn} do
      media_profile = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())
      source = source_fixture(media_profile_id: media_profile.id)

      {:ok, _view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      refute html =~ source.custom_name
    end

    test "shows the pending count for sources with no downloaded media", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_filepath: nil})
      media_item_fixture(%{source_id: source.id, media_filepath: nil})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(5)") == "2"
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(6)") == "0"
    end

    test "names the collection type of each source", %{conn: conn} do
      source_fixture(custom_name: "A_Channel", collection_type: "channel")
      source_fixture(custom_name: "B_Playlist", collection_type: "playlist")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(4)") =~ "Channel"
      assert cell_text(view, "tbody tr:last-child td:nth-of-type(4)") =~ "Playlist"
    end

    test "shows pending and downloaded counts for sources with downloaded media", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_filepath: nil})
      media_item_fixture(%{source_id: source.id})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(5)") == "1"
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(6)") == "1"
    end

    test "renders the table view when selected and exposes the poster grid toggle", %{conn: conn} do
      source = source_fixture(custom_name: "Grid candidate")

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert html =~ ~s(data-view="table")
      assert html =~ ~s(data-view-toggle="grid")
      assert html =~ ~s(aria-pressed="false")
      assert html =~ source.custom_name

      click_element(view, ~s([data-view-toggle="grid"]))

      grid_html = render_element(view, "#source-poster-grid")
      assert grid_html =~ source.custom_name
      assert grid_html =~ ~s(data-artwork-fallback)
      assert grid_html =~ ~s(href="/sources/#{source.id}")
      assert grid_html =~ ~s(href="/sources/#{source.id}/edit")
      assert grid_html =~ ~s(id="source-status-grid-#{source.id}" role="switch")
    end

    test "renders the same exact source ID set in table and poster-grid views", %{conn: conn} do
      sources = [
        source_fixture(custom_name: "Grid candidate A"),
        source_fixture(custom_name: "Grid candidate B")
      ]

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      expected_ids = sources |> Enum.map(& &1.id) |> MapSet.new()
      table_ids = source_ids(render_element(view, "#source-table"))

      click_element(view, ~s([data-view-toggle="grid"]))

      grid_ids = source_ids(render_element(view, "#source-poster-grid"))

      assert table_ids == expected_ids
      assert grid_ids == table_ids
    end

    test "keeps the sorted page while switching views", %{conn: conn} do
      source_a = source_fixture(custom_name: "Source_A")
      source_b = source_fixture(custom_name: "Source_B")

      session = Map.merge(create_session(), %{"results_per_page" => 1})
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      click_element(view, "button.pagination-next")
      assert render_element(view, "#source-table") =~ source_b.custom_name
      refute render_element(view, "#source-table") =~ source_a.custom_name

      click_element(view, ~s([data-view-toggle="grid"]))

      assert render_element(view, "#source-poster-grid") =~ source_b.custom_name
      refute render_element(view, "#source-poster-grid") =~ source_a.custom_name
      assert render(view) =~ "Page"

      click_element(view, ~s([data-view-toggle="table"]))
      assert render_element(view, "#source-table") =~ source_b.custom_name
      refute render_element(view, "#source-table") =~ source_a.custom_name
    end

    test "sorting the table leaves the grid in its default order", %{conn: conn} do
      alpha = source_fixture(custom_name: "Alpha")
      bravo = source_fixture(custom_name: "Bravo")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, ~s(th button[data-label="Name"]))
      assert ordered_source_ids(render_element(view, "#source-table")) == [bravo.id, alpha.id]

      click_element(view, ~s([data-view-toggle="grid"]))
      assert ordered_source_ids(render_element(view, "#source-poster-grid")) == [alpha.id, bravo.id]

      click_element(view, ~s([data-view-toggle="table"]))
      assert ordered_source_ids(render_element(view, "#source-table")) == [bravo.id, alpha.id]
      assert has_element?(view, ~s(th[aria-sort="descending"] button[data-label="Name"]))
    end
  end

  describe "poster-grid artwork" do
    test "shows artwork that finished loading before the page script started", %{conn: conn} do
      source = source_fixture(custom_name: "Cached artwork")
      session = Map.put(create_session(), "initial_view_mode", "grid")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      # Cached images (for example after the browser's back button) can load before Alpine listens for `load`.
      img = view |> element(~s(#source-card-#{source.id} img[alt="Artwork for Cached artwork"])) |> render()
      assert img =~ "image_loaded = $el.complete"
      assert img =~ "$el.naturalWidth"
      assert img =~ ~s(x-on:load="image_loaded = true")
    end
  end

  describe "poster-grid progress" do
    test "does not claim completion when the total is empty or unknown" do
      assert %{state: :empty, percent: 0, label: "No indexed media yet"} =
               IndexTableLive.source_progress(%{media_count: 0, downloaded_count: 0, pending_count: 0})

      assert %{state: :unknown, percent: nil} =
               IndexTableLive.source_progress(%{media_count: nil, downloaded_count: 0, pending_count: 0})

      assert %{state: :known, percent: 50, label: "1 of 2 downloaded"} =
               IndexTableLive.source_progress(%{media_count: 2, downloaded_count: 1, pending_count: 1})
    end

    test "measures against the items to download and names the skipped ones" do
      assert %{state: :known, percent: 100, label: "5 of 5 downloaded · 5 skipped"} =
               IndexTableLive.source_progress(%{media_count: 10, downloaded_count: 5, pending_count: 0})

      assert %{state: :known, percent: 80, label: "12 of 15 downloaded · 40 skipped"} =
               IndexTableLive.source_progress(%{media_count: 55, downloaded_count: 12, pending_count: 3})
    end

    test "says when every indexed item is skipped instead of claiming nothing is indexed" do
      assert %{state: :all_skipped, percent: nil, label: "Nothing to download · 3 skipped"} =
               IndexTableLive.source_progress(%{media_count: 3, downloaded_count: 0, pending_count: 0})
    end

    test "shows a caught-up source as complete in the poster grid", %{conn: conn} do
      source = source_fixture(custom_name: "Progress source")
      media_item_fixture(source_id: source.id)
      media_item_fixture(source_id: source.id, media_filepath: nil, prevent_download: true)
      skipped_only = source_fixture(custom_name: "Skipped source")
      media_item_fixture(source_id: skipped_only.id, media_filepath: nil, prevent_download: true)

      session = Map.put(create_session(), "initial_view_mode", "grid")
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      card = render_element(view, "#source-card-#{source.id}")
      assert card =~ "1 of 1 downloaded · 1 skipped"
      assert card =~ ~s(aria-valuenow="100")

      skipped_card = render_element(view, "#source-card-#{skipped_only.id}")
      assert skipped_card =~ ~s(data-progress-state="all_skipped")
      assert skipped_card =~ "Nothing to download · 1 skipped"
      refute skipped_card =~ ~s(role="progressbar")
    end
  end

  describe "when testing sorting" do
    test "sorts by the custom_name by default", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_B")
      source2 = source_fixture(custom_name: "Source_A")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end

    test "clicking the row will change the sort direction", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_B")
      source2 = source_fixture(custom_name: "Source_A")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      # Click the row to change the sort direction
      click_element(view, "th button", "Name")

      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source2.custom_name
    end

    test "clicking a different row will sort by that attribute", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_A")
      source2 = source_fixture(custom_name: "Source_B")
      media_item_fixture(source_id: source1.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      # Click the row to change the sort field
      click_element(view, "th button", "Downloaded")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name

      # Click the row to again change the sort direction
      click_element(view, "th button", "Downloaded")
      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source2.custom_name
    end

    test "name is sorted without case sensitivity", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_B")
      source2 = source_fixture(custom_name: "source_a")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end
  end

  describe "when sorting by the other columns" do
    test "sorts by pending count", %{conn: conn} do
      source1 = source_fixture(custom_name: "Has_Pending")
      source2 = source_fixture(custom_name: "No_Pending")
      media_item_fixture(%{source_id: source1.id, media_filepath: nil})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th button", "Pending")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end

    test "sorts by downloaded count", %{conn: conn} do
      source1 = source_fixture(custom_name: "Has_Downloads")
      source2 = source_fixture(custom_name: "No_Downloads")
      media_item_fixture(%{source_id: source1.id})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th button", "Downloaded")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end

    test "sorts by media size", %{conn: conn} do
      source1 = source_fixture(custom_name: "Big_Source")
      source2 = source_fixture(custom_name: "Small_Source")
      media_item_fixture(%{source_id: source1.id, media_size_bytes: 2_000})
      media_item_fixture(%{source_id: source2.id, media_size_bytes: 1_000})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      # media_item_fixture creates stray zero-size sources, so only the biggest
      # source has a deterministic position: last when ascending, first when
      # descending
      click_element(view, "th button", "Size")
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name

      click_element(view, "th button", "Size")
      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
    end

    test "sorts by collection type", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_A", collection_type: "channel")
      source2 = source_fixture(custom_name: "Source_B", collection_type: "playlist")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th button", "Type")

      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source2.custom_name

      click_element(view, "th button", "Type")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end

    test "sorts by media profile name without case sensitivity", %{conn: conn} do
      profile1 = media_profile_fixture(name: "zebra profile")
      profile2 = media_profile_fixture(name: "Apple Profile")
      source1 = source_fixture(custom_name: "Source_Z", media_profile_id: profile1.id)
      source2 = source_fixture(custom_name: "Source_A", media_profile_id: profile2.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th button", "Media Profile")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end
  end

  describe "when testing pagination" do
    test "moving to the next page loads new records", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_A")
      source2 = source_fixture(custom_name: "Source_B")

      session = Map.merge(create_session(), %{"results_per_page" => 1})
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      assert render_element(view, "tbody") =~ source1.custom_name
      refute render_element(view, "tbody") =~ source2.custom_name

      click_element(view, "button.pagination-next")

      refute render_element(view, "tbody") =~ source1.custom_name
      assert render_element(view, "tbody") =~ source2.custom_name
    end
  end

  describe "the status switch" do
    test "disables and enables a source from the table", %{conn: conn} do
      source = source_fixture(enabled: true)
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, ~s(button#source-status-table-#{source.id}[role="switch"][aria-checked="true"]))

      click_element(view, "#source-status-table-#{source.id}")
      assert %{enabled: false} = Repo.get!(Source, source.id)

      assert has_element?(
               view,
               ~s(#source-status-table-#{source.id}[aria-checked="false"][data-source-status="Disabled"])
             )

      click_element(view, "#source-status-table-#{source.id}")
      assert %{enabled: true} = Repo.get!(Source, source.id)
    end

    test "changes only the source whose poster-grid switch was clicked", %{conn: conn} do
      target = source_fixture(custom_name: "Target source", enabled: true)
      other = source_fixture(custom_name: "Other source", enabled: true)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      click_element(view, ~s([data-view-toggle="grid"]))
      click_element(view, "#source-status-grid-#{target.id}")

      assert %{enabled: false} = Repo.get!(Source, target.id)
      assert %{enabled: true} = Repo.get!(Source, other.id)
    end

    test "says what a click will do", %{conn: conn} do
      enabled = source_fixture(custom_name: "On source", enabled: true)
      disabled = source_fixture(custom_name: "Off source", enabled: false)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, ~s(#source-status-table-#{enabled.id}[aria-label$="Disable On source"]))
      assert has_element?(view, ~s(#source-status-table-#{disabled.id}[aria-label$="Enable Off source"]))
      assert has_element?(view, "#source-table [role=tooltip]", "Disabled")
      refute render(view) =~ "Click to"
    end
  end

  describe "status icon" do
    test "shows the state as a label for screen readers and on hover", %{conn: conn} do
      source = source_fixture(custom_name: "Paused source", download_media: false)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      switch = render_element(view, "#source-status-table-#{source.id}")
      refute switch =~ "title="
      assert has_element?(view, "#source-table td [role=tooltip]", "Indexing Enabled, No Automatic Downloads")
      assert switch =~ "Indexing Enabled, No Automatic Downloads"
      assert has_element?(view, ~s(th button[data-label="Status"]))
      refute has_element?(view, "th button", "Enabled?")
    end

    test "has four states: disabled, downloading, and a bolt for Download Media on or off" do
      for download_media <- [true, false], downloading <- [true, false] do
        assert %{label: "Disabled", icon: "hero-pause", switch_class: "theme-status-switch-neutral"} =
                 IndexTableLive.source_status(%{enabled: false, download_media: download_media}, downloading)
      end

      for download_media <- [true, false] do
        assert %{
                 label: "Downloading",
                 icon: "hero-clock",
                 switch_class: "theme-status-switch-warning theme-status-switch-busy"
               } =
                 IndexTableLive.source_status(%{enabled: true, download_media: download_media}, true)
      end

      assert %{
               label: "Indexing Enabled, No Automatic Downloads",
               icon: "hero-bolt",
               switch_class: "theme-status-switch-info"
             } =
               IndexTableLive.source_status(%{enabled: true, download_media: false}, false)

      assert %{
               label: "Indexing Enabled, Automatically Downloads",
               icon: "hero-bolt",
               switch_class: "theme-status-switch-success"
             } =
               IndexTableLive.source_status(%{enabled: true, download_media: true}, false)
    end

    test "shows the downloading state while download jobs are running or queued", %{conn: conn} do
      for {state, expected} <- [
            {"executing", "Downloading"},
            {"available", "Downloading"},
            {"completed", "Indexing Enabled, Automatically Downloads"}
          ] do
        source = source_fixture()
        media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

        {:ok, job} =
          %{id: media_item.id}
          |> Pinchflat.Downloading.MediaDownloadWorker.new()
          |> Oban.insert()

        {:ok, job} = job |> Ecto.Changeset.change(state: state) |> Repo.update()
        {:ok, _task} = Pinchflat.Tasks.create_task(job, media_item)

        {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

        assert has_element?(view, ~s(#source-status-table-#{source.id}[data-source-status="#{expected}"])),
               "expected #{expected} for a #{state} job"
      end
    end
  end

  describe "retention column" do
    test "shows the effective retention with its origin for assistive tech and on hover", %{conn: conn} do
      profile = media_profile_fixture(%{retention_period_days: 30})
      inherited = source_fixture(custom_name: "Inherited", media_profile_id: profile.id)
      override = source_fixture(custom_name: "Override", media_profile_id: profile.id, retention_period_days: 1)
      off = source_fixture(custom_name: "Off", media_profile_id: profile.id, retention_period_days: 0)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(
               view,
               ~s(th button[data-label="Download Retention Cutoff"] [data-icon="hero-archive-box-x-mark"])
             )

      assert row_retention(view, inherited) =~ "30 Days"
      assert row_retention(view, inherited) =~ "30 days (profile default)"
      assert row_retention(view, override) =~ "1 day (source override)"
      assert row_retention(view, off) =~ "Off"
      assert row_retention(view, off) =~ "No age-based cleanup (source override)"
    end

    test "sets a fixed or rolling download cutoff, or removes it, from the list", %{conn: conn} do
      source = source_fixture(custom_name: "Cutoff source")
      form = retention_form(source)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      for days <- [7, 14, 30, 60, 90, 180, 365] do
        assert has_element?(
                 view,
                 ~s|#{form} select[aria-label="Rolling window presets"] option[value="#{days}"]|,
                 "#{days} days"
               )
      end

      refute has_element?(view, ~s|#{form} input[name="retention_period_days"]|)

      refute render_element(view, "#source-table") =~ "Download cutoff:"

      view |> form(form, %{cutoff_mode: "days", download_cutoff_days: "14"}) |> render_submit()
      assert %{download_cutoff_days: 14, download_cutoff_date: nil} = Repo.reload!(source)
      assert render_element(view, "#source-table") =~ "Download cutoff: last 14 days."

      view |> form(form, %{cutoff_mode: "date", download_cutoff_date: "2020-01-31"}) |> render_submit()
      assert %{download_cutoff_days: nil, download_cutoff_date: ~D[2020-01-31]} = Repo.reload!(source)

      view |> form(form, %{cutoff_mode: "none"}) |> render_submit()
      assert %{download_cutoff_days: nil, download_cutoff_date: nil} = Repo.reload!(source)

      view |> form(form, %{cutoff_mode: "days", download_cutoff_days: ""}) |> render_submit()
      assert render(view) =~ "Enter how many days the rolling window covers."
      assert %{download_cutoff_days: nil} = Repo.reload!(source)
    end

    test "keeps the cutoff fields from being reset by list refreshes", %{conn: conn} do
      source = source_fixture(custom_name: "Refreshing source", download_cutoff_days: 14)
      form = retention_form(source)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      fields = ~s(#{form} [phx-update="ignore"][id$="-fields-days--14"])
      assert has_element?(view, fields)
      html = render_element(view, fields)
      assert length(Regex.scan(~r/<fieldset[^>]*x-bind:disabled=/, html)) == 2
      assert has_element?(view, ~s(#{fields} fieldset input[name=download_cutoff_days]))

      send(view.pid, :throttled_refresh)
      assert has_element?(view, fields)

      view |> form(form, %{cutoff_mode: "days", download_cutoff_days: "30"}) |> render_submit()
      refute has_element?(view, fields)
      assert has_element?(view, ~s(#{form} [phx-update="ignore"][id$="-fields-days--30"]))
    end

    test "asks for a second Apply before a cutoff makes downloaded items deletable", %{conn: conn} do
      source = source_fixture(custom_name: "Old downloads")
      media_item_fixture(source_id: source.id, uploaded_at: ~U[2019-06-01 00:00:00Z])
      form = retention_form(source)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      view |> form(form, %{cutoff_mode: "date", download_cutoff_date: "2020-01-01"}) |> render_submit()
      assert Repo.reload!(source).download_cutoff_date == nil
      assert render(view) =~ "1 downloaded item was published before 2020-01-01"
      assert has_element?(view, "#{form} button[type=submit]", "Apply and Delete 1")

      view |> form(form, %{cutoff_mode: "date", download_cutoff_date: "2020-01-01"}) |> render_submit()
      assert Repo.reload!(source).download_cutoff_date == ~D[2020-01-01]
      refute render(view) =~ "Apply and Delete"
    end

    test "uses a short label" do
      assert IndexTableLive.retention_short_label(%{
               retention_period_days: nil,
               media_profile: %{retention_period_days: 7}
             }) ==
               "7 Days"

      assert IndexTableLive.retention_short_label(%{retention_period_days: 1, media_profile: nil}) == "1 Day"
      assert IndexTableLive.retention_short_label(%{retention_period_days: 0, media_profile: nil}) == "Off"
      assert IndexTableLive.retention_short_label(%{retention_period_days: nil, media_profile: nil}) == "Off"
    end
  end

  describe "indexing column" do
    test "shows how often each source is indexed in the table and the poster grid", %{conn: conn} do
      daily = source_fixture(custom_name: "Daily", index_frequency_minutes: 24 * 60)
      fast = source_fixture(custom_name: "Fast", fast_index: true)
      once = source_fixture(custom_name: "Once", index_frequency_minutes: -1)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, ~s(th button[data-label="Index Frequency"] [data-icon="hero-clock"]))
      assert render_element(view, "#source-indexing-#{daily.id}") =~ "Daily"
      assert render_element(view, "#source-indexing-mobile-#{daily.id}") =~ "Daily"
      assert has_element?(view, "#source-retention-mobile-#{daily.id}")
      refute has_element?(view, "article p", "Retention:")
      assert render_element(view, "#source-indexing-#{daily.id}") =~ "Indexed every day"
      assert render_element(view, "#source-indexing-#{fast.id}") =~ "10 Min"
      assert render_element(view, "#source-indexing-#{once.id}") =~ "Indexed only once"

      session = Map.put(create_session(), "initial_view_mode", "grid")
      {:ok, grid, _html} = live_isolated(conn, IndexTableLive, session: session)
      assert render_element(grid, "#source-indexing-grid-#{daily.id}") =~ "Daily"
    end

    test "changes a source's index frequency from the list", %{conn: conn} do
      source = source_fixture(custom_name: "Editable", index_frequency_minutes: 24 * 60)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      option = ~s(#source-table button[phx-click="set_source_index_frequency"][phx-value-id="#{source.id}"])

      for {label, _minutes} <- PinchflatWeb.Sources.SourceHTML.friendly_index_frequencies() do
        assert has_element?(view, option, label)
      end

      assert has_element?(view, ~s(#{option}[aria-current="true"]), "Daily (recommended)")

      view |> element(~s(#{option}[phx-value-minutes="360"])) |> render_click()

      assert Repo.reload!(source).index_frequency_minutes == 360
      assert render_element(view, "#source-indexing-#{source.id}") =~ "6 Hours"
    end

    test "leaves the index frequency read-only with fast indexing or for a single video", %{conn: conn} do
      fast = source_fixture(custom_name: "Fast", fast_index: true)
      video = source_fixture(custom_name: "Video", collection_type: :video, index_frequency_minutes: 0)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      refute has_element?(view, ~s(button[phx-click="set_source_index_frequency"][phx-value-id="#{fast.id}"]))

      render_hook(view, "set_source_index_frequency", %{"id" => to_string(fast.id), "minutes" => "360"})
      assert Repo.reload!(fast).index_frequency_minutes == fast.index_frequency_minutes

      session = Map.put(create_session(), "source_type", "videos")
      {:ok, videos, _html} = live_isolated(conn, IndexTableLive, session: session)
      assert render_element(videos, "#source-indexing-#{video.id}") =~ "Once"
      refute has_element?(videos, ~s(button[phx-click="set_source_index_frequency"]))
    end

    test "uses a short label with the full wording for the tooltip" do
      assert {"Daily", "Indexed every day"} = IndexTableLive.index_frequency_labels(%{index_frequency_minutes: 1440})

      assert {"30 Min", "Indexed every 30 minutes"} =
               IndexTableLive.index_frequency_labels(%{index_frequency_minutes: 30})

      assert {"Hourly", "Indexed every hour"} = IndexTableLive.index_frequency_labels(%{index_frequency_minutes: 60})
      assert {"6 Hours", _} = IndexTableLive.index_frequency_labels(%{index_frequency_minutes: 360})
      assert {"Monthly", _} = IndexTableLive.index_frequency_labels(%{index_frequency_minutes: 43_200})
      assert {"10 Min", _} = IndexTableLive.index_frequency_labels(%{fast_index: true, index_frequency_minutes: 43_200})
      assert {"Once", _} = IndexTableLive.index_frequency_labels(%{fast_index: false, index_frequency_minutes: 0})
      assert {"Once", _} = IndexTableLive.index_frequency_labels(%{index_frequency_minutes: -1})
    end
  end

  describe "sorting by status" do
    test "orders automatic downloads, then no automatic downloads, then disabled, ignoring downloads", %{conn: conn} do
      disabled = source_fixture(custom_name: "A disabled", enabled: false)
      no_downloads = source_fixture(custom_name: "B no downloads", download_media: false)
      downloading = source_fixture(custom_name: "C downloading")
      automatic = source_fixture(custom_name: "D automatic")

      media_item = media_item_fixture(source_id: downloading.id, media_filepath: nil)
      {:ok, job} = %{id: media_item.id} |> Pinchflat.Downloading.MediaDownloadWorker.new() |> Oban.insert()
      {:ok, _task} = Pinchflat.Tasks.create_task(job, media_item)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      render_click(view, "sort_update", %{"sort_key" => "status"})

      assert ordered_source_ids(render_element(view, "#source-table")) ==
               [downloading.id, automatic.id, no_downloads.id, disabled.id]

      render_click(view, "sort_update", %{"sort_key" => "status"})

      assert ordered_source_ids(render_element(view, "#source-table")) ==
               [disabled.id, no_downloads.id, downloading.id, automatic.id]
    end
  end

  describe "sorting by index frequency and retention" do
    test "orders sources by how often they are indexed, with fast indexing first and once-only last",
         %{conn: conn} do
      weekly = source_fixture(custom_name: "A weekly", index_frequency_minutes: 7 * 24 * 60)
      once = source_fixture(custom_name: "B once", index_frequency_minutes: -1)
      fast = source_fixture(custom_name: "C fast", fast_index: true, index_frequency_minutes: 30 * 24 * 60)
      hourly = source_fixture(custom_name: "D hourly", index_frequency_minutes: 60)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      render_click(view, "sort_update", %{"sort_key" => "index_frequency"})
      assert ordered_source_ids(render_element(view, "#source-table")) == [fast.id, hourly.id, weekly.id, once.id]

      render_click(view, "sort_update", %{"sort_key" => "index_frequency"})
      assert ordered_source_ids(render_element(view, "#source-table")) == [once.id, weekly.id, hourly.id, fast.id]
    end

    test "orders sources by their effective retention, with retention off last", %{conn: conn} do
      profile = media_profile_fixture(%{retention_period_days: 30})
      inherited = source_fixture(custom_name: "A inherited", media_profile_id: profile.id)
      off = source_fixture(custom_name: "B off", media_profile_id: profile.id, retention_period_days: 0)
      short = source_fixture(custom_name: "C short", media_profile_id: profile.id, retention_period_days: 3)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      render_click(view, "sort_update", %{"sort_key" => "retention"})
      assert ordered_source_ids(render_element(view, "#source-table")) == [short.id, inherited.id, off.id]
    end
  end

  describe "live PubSub updates" do
    test "updates source counts when job:state change event is broadcast", %{conn: conn} do
      source = source_fixture(custom_name: "A_Live_Update_Source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(5)") == "0"

      # Add a pending media item after mount
      media_item_fixture(%{source_id: source.id, media_filepath: nil})

      # Broadcast job:state change
      PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)
      :timer.sleep(50)

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(5)") == "1"
    end

    test "ignores job:progress updates because they do not change source totals", %{conn: conn} do
      source = source_fixture(custom_name: "A_Progress_Update_Source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      media_item_fixture(%{source_id: source.id})

      PinchflatWeb.Endpoint.broadcast("job:progress", "update", %{job_id: 123})
      :timer.sleep(50)

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(6)") == "0"
    end

    test "throttles rapid job:state events and applies later changes on the trailing refresh", %{conn: conn} do
      source = source_fixture(custom_name: "A_Throttled_Update_Source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)
      :timer.sleep(50)

      # Added inside the throttle window, so further events must not refresh the table yet
      media_item_fixture(%{source_id: source.id})
      Enum.each(1..5, fn _ -> PinchflatWeb.Endpoint.broadcast("job:state", "change", nil) end)
      :timer.sleep(50)
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(6)") == "0"

      send(view.pid, :throttled_refresh)
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(6)") == "1"
    end
  end

  describe "tab header" do
    test "puts the view toggle on the tab row without the old view heading", %{conn: conn} do
      source_fixture()

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, ~s(header nav a[aria-current="page"]), "Channels & Playlists")
      assert has_element?(view, "header nav a", "Individual Videos")
      assert has_element?(view, ~s([data-view-toggle="grid"]), "Poster Grid")
      assert has_element?(view, ~s(header [role="group"][aria-label="Source view"] [data-view-toggle="grid"]))
      refute html =~ "Choose a table or poster library layout."
      refute has_element?(view, "p", "Source view")
    end

    test "keeps the selected view in the tab links", %{conn: conn} do
      source_fixture()
      session = Map.put(create_session(), "source_type", "videos")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      assert has_element?(view, ~s(header nav a[href="/sources?type=channels&view=table"]))
      assert has_element?(view, ~s(header nav a[href="/sources?type=videos&view=table"][aria-current="page"]))

      click_element(view, ~s([data-view-toggle="grid"]))

      assert has_element?(view, ~s(header nav a[href="/sources?type=channels"]))
      assert has_element?(view, ~s(header nav a[href="/sources?type=videos"][aria-current="page"]))
    end
  end

  describe "table columns" do
    test "shows pending and downloaded headers as labelled, sortable icons", %{conn: conn} do
      source_fixture()

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      for {label, icon} <- [{"Pending", "hero-queue-list"}, {"Downloaded", "hero-check-circle"}] do
        assert has_element?(view, ~s(th button[data-label="#{label}"] [data-icon="#{icon}"]))
        assert has_element?(view, ~s(th button[data-label="#{label}"] span.sr-only), label)
        # The column name shows in the styled tooltip, not the browser's title.
        assert has_element?(view, ~s(th [role="tooltip"][popover="manual"]), label)
      end
    end

    test "shows the source type as an icon with its name on hover when the table is narrow", %{conn: conn} do
      source_fixture(collection_type: :playlist)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, ~s(#source-table td span[class*="@max-5xl:hidden"]), "Playlist")
      assert has_element?(view, ~s(#source-table td [data-tooltip-anchor] [data-icon="hero-queue-list"]))
      assert has_element?(view, ~s(#source-table td [role="tooltip"]), "Playlist")
    end

    test "marks the sorted column with one arrow above or below its label", %{conn: conn} do
      source_fixture()

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      refute has_element?(view, ~s(th button[data-label="Pending"] [data-sort-arrow]))
      # The button's overlay fills its header cell, so clicking anywhere in the cell sorts.
      assert has_element?(view, ~s(th.relative button[data-label="Pending"][class*="after:inset-0"]))

      click_element(view, ~s(th button[data-label="Pending"]))

      direction =
        if has_element?(view, ~s(th[aria-sort="ascending"] button[data-label="Pending"])), do: "asc", else: "desc"

      arrow = if direction == "asc", do: "up", else: "down"

      assert has_element?(view, ~s(th button[data-label="Pending"][data-sorted="#{direction}"]))
      refute has_element?(view, ~s(th[class*="bg-theme-primary"]))
      refute has_element?(view, ~s(th button[data-label="Pending"].text-theme-primary))
      assert has_element?(view, ~s(th button[data-label="Pending"] [data-sort-arrow="#{arrow}"] svg))
      arrows = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(~s(th button[data-label="Pending"] svg))
      assert Enum.count(arrows) == 1
      refute has_element?(view, ~s(th button[data-label="Downloaded"][data-sorted]))
    end
  end

  describe "changing a media profile from the list" do
    test "assigns the chosen profile without a success toast", %{conn: conn} do
      current = media_profile_fixture(name: "Current profile")
      target = media_profile_fixture(name: "Target profile")
      source = source_fixture(custom_name: "Profile source", media_profile_id: current.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      option = ~s(#source-table button[phx-click="assign_source_profile"][phx-value-profile_id="#{target.id}"])
      assert has_element?(view, option)

      click_element(view, option)

      assert Repo.reload!(source).media_profile_id == target.id

      refute has_element?(view, "#source-notice-toasts [role=status]")
      assert has_element?(view, ~s(#source-table button[aria-label^="Target profile, change"]))

      assert has_element?(view, ~s(#source-table button[aria-current="true"][phx-value-profile_id="#{target.id}"]))
    end

    test "marks the current profile and does not offer it as a change", %{conn: conn} do
      current = media_profile_fixture(name: "Current profile")
      source_fixture(media_profile_id: current.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      current_option = ~s(#source-table button[phx-value-profile_id="#{current.id}"])
      assert has_element?(view, current_option <> ~s([disabled][aria-current="true"]))
      refute render_element(view, current_option) =~ "bg-theme-primary/15"
    end

    test "leaves the source unchanged for a profile that is not offered", %{conn: conn} do
      current = media_profile_fixture()
      deleted = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())
      source = source_fixture(media_profile_id: current.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      render_click(view, "assign_source_profile", %{"id" => to_string(source.id), "profile_id" => to_string(deleted.id)})

      assert Repo.reload!(source).media_profile_id == current.id
      assert render_element(view, "#source-notice-toasts") =~ "Could not change the media profile."
    end
  end

  describe "selecting sources" do
    test "the select-all checkbox selects and clears every source", %{conn: conn} do
      first = source_fixture(custom_name: "First")
      second = source_fixture(custom_name: "Second")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "#source-select-all-mobile")
      assert has_element?(view, "#source-select-all-mobile[checked]")
      assert has_element?(view, "#selected-source-actions", "2 selected")
      assert has_element?(view, "#selected-source-cutoff input[value='#{first.id}']")
      assert has_element?(view, "#selected-source-cutoff input[value='#{second.id}']")
      refute has_element?(view, "#source-select-all")

      click_element(view, "#source-select-all-mobile")
      assert has_element?(view, ~s(#selected-source-actions[data-selected-count="0"]), "None selected")

      for action <- ["#pause-selected-sources button", "#resume-selected-sources button", "button[phx-click]"] do
        assert has_element?(view, "#selected-source-actions #{action}[disabled]")
      end

      refute has_element?(view, "button[aria-label='Clear selection']")

      assert has_element?(view, "#selected-source-profile button[x-ref=trigger][disabled]")
      assert has_element?(view, "#selected-source-cutoff-menu button[disabled]")
      assert has_element?(view, "#selected-source-frequency button[disabled]")
    end

    test "either view button switches to the other view", %{conn: conn} do
      source_fixture()

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      click_element(view, ~s([data-view-toggle="table"]))
      assert has_element?(view, "#source-poster-grid")

      click_element(view, ~s([data-view-toggle="grid"]))
      assert has_element?(view, "#source-table")
    end

    test "the table header checkbox selects every source, and the status column sorts by enabled", %{conn: conn} do
      first = source_fixture(custom_name: "First")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, "#source-table th #source-select-all-table")
      assert has_element?(view, ~s(#source-table th button[data-label="Status"][phx-value-sort_key="status"]))

      click_element(view, "#source-select-all-table")
      assert has_element?(view, "#source-select-all-table[checked]")
      assert has_element?(view, "#selected-source-cutoff input[value='#{first.id}']")

      click_element(view, ~s([data-view-toggle="grid"]))
      assert has_element?(view, ~s(#source-select-all-grid[aria-pressed="true"]), "Clear All")
      refute has_element?(view, "#source-select-all-table")
      refute has_element?(view, "#source-select-all-mobile")
    end

    test "poster cards open the source and their corner tick selects them", %{conn: conn} do
      first = source_fixture(custom_name: "First")
      second = source_fixture(custom_name: "Second")
      session = Map.put(create_session(), "initial_view_mode", "grid")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      refute has_element?(view, "#source-poster-grid input[name=source_selection]")
      refute render_element(view, "#source-poster-grid") =~ "Not monitored"
      assert has_element?(view, "#source-select-all-grid", "Select All")

      assert has_element?(
               view,
               ~s(#source-card-#{first.id} a[aria-label="Open source First"][href="/sources/#{first.id}"])
             )

      assert has_element?(view, ~s(#source-card-#{first.id} a[href="/sources/#{first.id}/edit"]))
      assert has_element?(view, ~s(#source-card-#{first.id} button[aria-label="More actions for First"]))
      assert has_element?(view, ~s(#source-card-#{first.id} h3.line-clamp-2[title="First"]))
      assert has_element?(view, ~s(#source-card-#{first.id} .theme-source-card-head #source-status-grid-#{first.id}))

      delete = ~s(#source-card-#{first.id} button[aria-label="Delete First"])
      assert has_element?(view, delete <> ".theme-outline-button")
      refute has_element?(view, delete <> ".theme-danger-button")

      click_element(view, "#source-select-grid-#{first.id}")

      assert has_element?(view, ~s(#source-card-#{first.id}[data-selected="true"].ring-2))
      assert has_element?(view, ~s(#source-select-grid-#{first.id}[aria-pressed="true"]))
      assert has_element?(view, ~s(#source-card-#{second.id}[data-selected="false"]))
      assert has_element?(view, "#selected-source-actions", "1 selected")

      click_element(view, "#source-select-grid-#{first.id}")
      assert has_element?(view, ~s(#source-card-#{first.id}[data-selected="false"]))

      click_element(view, "#source-select-all-grid")
      assert has_element?(view, "#selected-source-actions", "2 selected")
    end

    test "selects every source in the tab and keeps it across pages", %{conn: conn} do
      first = source_fixture(custom_name: "First")
      second = source_fixture(custom_name: "Second")
      third = source_fixture(custom_name: "Third")
      video = source_fixture(custom_name: "Video", collection_type: :video)
      session = Map.put(create_session(), "results_per_page", 2)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      click_element(view, "#source-select-all-mobile")
      assert has_element?(view, "#source-select-all", "All 3 channels & playlists are selected.")
      assert has_element?(view, "#source-select-all-mobile[checked]")

      for source <- [first, second, third] do
        assert has_element?(view, "#selected-source-cutoff input[value='#{source.id}']")
      end

      refute has_element?(view, "#selected-source-cutoff input[value='#{video.id}']")

      click_element(view, "button.pagination-next")
      assert has_element?(view, "#selected-source-actions", "3 selected")
      assert has_element?(view, "#source-select-table-#{third.id}[checked]")

      click_element(view, "#source-select-table-#{third.id}")
      assert has_element?(view, "#source-select-all", "2 of 3 channels & playlists are selected.")

      click_element(view, "#source-select-all button", "Clear Selection")
      assert has_element?(view, ~s(#selected-source-actions[data-selected-count="0"]))
    end

    test "select all only covers the sources matching the search", %{conn: conn} do
      zebra_a = source_fixture(custom_name: "Zebra A")
      zebra_b = source_fixture(custom_name: "Zebra B")
      other = source_fixture(custom_name: "Other")
      session = Map.put(create_session(), "results_per_page", 1)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)
      search(view, "zebra")

      click_element(view, "#source-select-all-mobile")

      assert has_element?(view, "#selected-source-cutoff input[value='#{zebra_a.id}']")
      assert has_element?(view, "#selected-source-cutoff input[value='#{zebra_b.id}']")
      refute has_element?(view, "#selected-source-cutoff input[value='#{other.id}']")

      search(view, "other")
      assert has_element?(view, ~s(#selected-source-actions[data-selected-count="0"]))
    end

    test "keeps the actions on the search row and the cutoff form in its menu", %{conn: conn} do
      source_fixture()

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      click_element(view, "#source-select-all-mobile")

      assert has_element?(view, "#source-toolbar #source-search-form.max-sm\\:basis-full")
      assert has_element?(view, "#source-toolbar #selected-source-actions")

      assert has_element?(view, "#selected-source-cutoff-menu form#selected-source-cutoff")
      assert has_element?(view, "#selected-source-cutoff select[name=cutoff_mode] option[value=days]")
      assert has_element?(view, "#selected-source-cutoff input[name=cutoff_days]")
      assert has_element?(view, ~s(#selected-source-cutoff select[aria-label="Rolling window presets"]))
    end

    test "shows only icons for the bulk buttons on phones until they ask for confirmation", %{conn: conn} do
      source_fixture()

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      click_element(view, "#source-select-all-mobile")

      for id <- ["pause-selected-sources", "resume-selected-sources"] do
        assert has_element?(view, "##{id} button span.max-sm\\:sr-only")
      end

      assert has_element?(view, "#selected-source-actions button span.max-sm\\:sr-only", "Delete")
      assert has_element?(view, "#selected-source-frequency button span.max-sm\\:sr-only", "Index Frequency")
      assert has_element?(view, "#selected-source-cutoff-menu button span.max-sm\\:sr-only", "Download Cutoff")
      assert has_element?(view, "#selected-source-profile button span.lg\\:hidden", "Profile")
      assert has_element?(view, "#selected-source-profile button span.max-lg\\:hidden", "Media Profile")

      view |> element("#pause-selected-sources button") |> render_click()
      refute has_element?(view, "#pause-selected-sources button span.max-sm\\:sr-only")
    end

    test "turns automatic downloads off and on from the bulk More actions menu", %{conn: conn} do
      source = source_fixture(custom_name: "Bulk downloads", download_media: true)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")

      off = ~s(#selected-source-jobs button[phx-value-action="pause"])
      on = ~s(#selected-source-jobs button[phx-value-action="resume"])
      assert has_element?(view, off, "Disable Automatic Downloads")
      assert has_element?(view, on, "Enable Automatic Downloads")

      view |> element(off) |> render_click()
      assert has_element?(view, ~s(#{off}[data-armed="true"]), "Disable Automatic Downloads for 1?")
      assert Repo.reload!(source).download_media

      ripen_armed(view)
      view |> element(off) |> render_click()
      refute Repo.reload!(source).download_media

      view |> element(on) |> render_click()
      ripen_armed(view)
      view |> element(on) |> render_click()
      assert Repo.reload!(source).download_media
    end

    test "sets the index frequency of the selected sources on a second click", %{conn: conn} do
      daily = source_fixture(custom_name: "Daily", index_frequency_minutes: 24 * 60)
      fast = source_fixture(custom_name: "Fast", fast_index: true, index_frequency_minutes: 30 * 24 * 60)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")

      option = ~s(#selected-source-frequency button[phx-value-minutes="360"])
      view |> element(option) |> render_click()
      assert has_element?(view, ~s(#{option}[data-armed="true"]), "Use 6 Hours for 2?")
      assert Repo.reload!(daily).index_frequency_minutes == 24 * 60

      ripen_armed(view)
      view |> element(option) |> render_click()

      assert Repo.reload!(daily).index_frequency_minutes == 360
      assert Repo.reload!(fast).index_frequency_minutes == 30 * 24 * 60
      assert render(view) =~ "Index frequency changed for 1 source. 1 with fast indexing or a single video"
    end
  end

  describe "bulk actions" do
    test "pause needs a second click, then runs without leaving the page", %{conn: conn} do
      first = source_fixture(custom_name: "First", download_media: true)
      second = source_fixture(custom_name: "Second", download_media: true)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")

      view |> element("#pause-selected-sources button") |> render_click()
      assert has_element?(view, ~s(#pause-selected-sources button[data-armed="true"].theme-confirm-pending), "Pause 2?")
      assert Pinchflat.Repo.reload!(first).download_media

      ripen_armed(view)
      view |> element("#pause-selected-sources button") |> render_click()
      refute Pinchflat.Repo.reload!(first).download_media
      refute Pinchflat.Repo.reload!(second).download_media
      assert has_element?(view, "#pause-selected-sources button.theme-success-button", "Paused")
      refute has_element?(view, "#source-notice-toasts [role=status]")

      send(view.pid, {:clear_done, :pause})
      assert has_element?(view, "#pause-selected-sources button.theme-outline-button", "Pause")
    end

    test "a double-click arms the action without running it", %{conn: conn} do
      source = source_fixture(custom_name: "Only", download_media: true)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")

      view |> element("#pause-selected-sources button") |> render_click()
      view |> element("#pause-selected-sources button") |> render_click()
      assert Pinchflat.Repo.reload!(source).download_media
      assert has_element?(view, ~s(#pause-selected-sources button[data-armed="true"]), "Pause 1?")

      ripen_armed(view)
      view |> element("#pause-selected-sources button") |> render_click()
      refute Pinchflat.Repo.reload!(source).download_media
    end

    test "an armed action lapses and needs both clicks again", %{conn: conn} do
      source = source_fixture(custom_name: "Only", download_media: false)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")
      view |> element("#resume-selected-sources button") |> render_click()

      ref = :sys.get_state(view.pid).socket.assigns.armed |> elem(2)
      send(view.pid, {:disarm_bulk, ref})
      assert has_element?(view, ~s(#resume-selected-sources button[data-armed="false"]), "Resume")
      refute Pinchflat.Repo.reload!(source).download_media
    end

    test "changing the selection disarms an armed action", %{conn: conn} do
      first = source_fixture(custom_name: "First", download_media: true)
      second = source_fixture(custom_name: "Second", download_media: true)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_source_selection", %{"id" => "#{first.id}"})
      view |> element("#pause-selected-sources button") |> render_click()

      render_click(view, "toggle_source_selection", %{"id" => "#{second.id}"})
      assert has_element?(view, ~s(#pause-selected-sources button[data-armed="false"]))

      view |> element("#pause-selected-sources button") |> render_click()
      assert Pinchflat.Repo.reload!(first).download_media
    end

    test "a media profile choice needs a second click", %{conn: conn} do
      current = media_profile_fixture(name: "Current")
      target = media_profile_fixture(name: "Target")
      source = source_fixture(custom_name: "Source", media_profile_id: current.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")
      option = ~s(#selected-source-profile button[phx-value-profile_id="#{target.id}"])

      view |> element(option) |> render_click()
      assert has_element?(view, option <> ~s([data-armed="true"]), "Use Target for 1?")
      assert Pinchflat.Repo.reload!(source).media_profile_id == current.id

      ripen_armed(view)
      view |> element(option) |> render_click()
      assert Pinchflat.Repo.reload!(source).media_profile_id == target.id
      assert has_element?(view, "#selected-source-profile button.theme-success-button", "Profile Changed")
    end
  end

  describe "source actions" do
    test "each source's More actions menu has the source page's actions", %{conn: conn} do
      busy = source_fixture(custom_name: "Busy")
      media_item_fixture(source_id: busy.id, media_filepath: nil)
      media_item_fixture(source_id: busy.id)
      empty = source_fixture(custom_name: "Empty")
      session = Map.put(create_session(), "initial_view_mode", "grid")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)
      card = render_element(view, "#source-card-#{busy.id}")

      for label <-
            ["Use as Template", "Download Pending", "Redownload Existing", "Force Index"] ++
              ["Refresh Metadata", "Sync Files on Disk", "Reconcile Files", "Downloads"] do
        assert card =~ label
      end

      menu = ~s(#source-card-#{busy.id} button[phx-click="source_job"][phx-value-id="#{busy.id}"])
      assert has_element?(view, ~s(#{menu}[phx-value-action="force_index"]))
      assert has_element?(view, ~s(#{menu}[phx-value-action="download_pending"]))
      assert card =~ ~s(href="/reconciliation?source_id=#{busy.id}")
      assert card =~ ~s(href="/sources/new?template_id=#{busy.id}")
      refute card =~ ~s(action="/sources/#{busy.id}/force_index")
      refute card =~ "Copy JSON"
      refute card =~ "Copy RSS Feed"

      empty_card = render_element(view, "#source-card-#{empty.id}")
      refute empty_card =~ ~s(phx-value-action="download_pending")
      refute empty_card =~ ~s(phx-value-action="redownload_existing")
      refute empty_card =~ "Download Pending"
      assert empty_card =~ ~r/Redownload Existing\s*<span[^>]*>Nothing downloaded/
      assert empty_card =~ "Force Index"
    end

    test "a narrow table moves Edit and Delete into the row's More actions", %{conn: conn} do
      source = source_fixture(custom_name: "Narrow")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, ~s(#source-table div[class*="@max-4xl:hidden"] a[href="/sources/#{source.id}/edit"]))

      assert has_element?(
               view,
               ~s(#source-table li a[class*="@max-4xl:flex"][href="/sources/#{source.id}/edit"]),
               "Edit"
             )

      assert has_element?(
               view,
               ~s(#source-table li button[class*="@max-4xl:flex"][phx-click*="confirm_delete"]),
               "Delete"
             )

      refute has_element?(view, ~s(#source-poster-grid li a[href="/sources/#{source.id}/edit"]))
    end

    test "the selection's More actions queue a job for every selected source on a second click", %{conn: conn} do
      sources = [source_fixture(custom_name: "First"), source_fixture(custom_name: "Second")]

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      assert has_element?(view, "#selected-source-jobs button[x-ref=trigger][disabled]")

      render_click(view, "toggle_select_all")
      option = ~s(#selected-source-jobs button[phx-value-action="force_index"])

      view |> element(option) |> render_click()
      assert has_element?(view, option <> ~s([data-armed="true"]), "Force Index for 2?")
      assert [] = all_enqueued(worker: Pinchflat.SlowIndexing.MediaCollectionIndexingWorker)

      ripen_armed(view)
      view |> element(option) |> render_click()
      render_async(view)

      enqueued = all_enqueued(worker: Pinchflat.SlowIndexing.MediaCollectionIndexingWorker)
      assert Enum.sort(Enum.map(enqueued, & &1.args["id"])) == Enum.sort(Enum.map(sources, & &1.id))
      assert render_element(view, "#source-notice-toasts") =~ "Force Index for 2 sources: 2 queued."
      refute has_element?(view, "#selected-source-jobs button[x-ref=trigger][disabled]")
    end

    test "the selection's More actions only reconcile one source at a time", %{conn: conn} do
      first = source_fixture(custom_name: "First")
      second = source_fixture(custom_name: "Second")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      render_click(view, "toggle_source_selection", %{"id" => "#{first.id}"})
      assert has_element?(view, ~s(#selected-source-jobs a[href="/reconciliation?source_id=#{first.id}"]))

      render_click(view, "toggle_source_selection", %{"id" => "#{second.id}"})
      assert has_element?(view, "#selected-source-jobs button[disabled]", "One source at a time")
      refute has_element?(view, "#selected-source-jobs a[href^='/reconciliation']")
    end

    test "ignores unknown bulk actions", %{conn: conn} do
      source_fixture()

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      render_click(view, "toggle_select_all")
      render_click(view, "bulk_job", %{"action" => "delete_everything"})

      refute has_element?(view, ~s(#selected-source-jobs button[data-armed="true"]))
    end
  end

  describe "searching" do
    test "searches every page of the selected tab", %{conn: conn} do
      source_fixture(custom_name: "Alpha zebra")
      source_fixture(custom_name: "Bravo")
      source_fixture(custom_name: "Charlie Zebra")
      source_fixture(custom_name: "Zebra video", collection_type: :video)
      session = Map.put(create_session(), "results_per_page", 1)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)
      assert render_element(view, "#source-table") =~ "Alpha zebra"

      search(view, "zebra")

      assert summary_text(view) == "Showing 2 of 3 channels & playlists for “zebra”"
      assert text(render_element(view, "nav[aria-label=Pagination]")) =~ "Page 1 of 2"
      assert render_element(view, "#source-table") =~ "Alpha zebra"

      click_element(view, "button.pagination-next")

      assert render_element(view, "#source-table") =~ "Charlie Zebra"
      refute render(view) =~ "Bravo"
      refute render(view) =~ "Zebra video"
    end

    test "only searches individual videos on the videos tab", %{conn: conn} do
      source_fixture(custom_name: "Zebra channel")
      source_fixture(custom_name: "Zebra video", collection_type: :video)
      source_fixture(custom_name: "Other video", collection_type: :video)
      session = Map.put(create_session(), "source_type", "videos")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      assert has_element?(view, ~s(#source-search-input[placeholder="Search individual videos"]))

      search(view, "zebra")

      assert summary_text(view) == "Showing 1 of 2 individual videos for “zebra”"
      assert render(view) =~ "Zebra video"
      refute render(view) =~ "Zebra channel"
      refute render(view) =~ "Other video"
    end

    test "matches the collection name but not the URL", %{conn: conn} do
      source_fixture(custom_name: "Renamed one", collection_name: "Original Zebra Channel")
      source_fixture(custom_name: "Renamed two", original_url: "https://www.youtube.com/@zebrahandle")
      source_fixture(custom_name: "Unrelated")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      html = search(view, "ZEBRA")
      assert html =~ "Renamed one"
      refute html =~ "Renamed two"
      refute html =~ "Unrelated"
    end

    test "treats LIKE wildcards in the term literally", %{conn: conn} do
      source_fixture(custom_name: "100% Zebra")
      source_fixture(custom_name: "100 Zebra")
      source_fixture(custom_name: "a_b Zebra")
      source_fixture(custom_name: "acb Zebra")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      html = search(view, "100%")
      assert html =~ "100% Zebra"
      refute html =~ "100 Zebra"

      html = search(view, "a_b")
      assert html =~ "a_b Zebra"
      refute html =~ "acb Zebra"
    end

    test "shows a no-match state that clears the search", %{conn: conn} do
      source_fixture(custom_name: "Zebra source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      search(view, "nothing-matches")

      assert has_element?(view, "#source-search-empty h3", "No channels & playlists match “nothing-matches”")
      refute has_element?(view, "h3", "No channels or playlists yet")
      refute has_element?(view, "#source-table")
      assert has_element?(view, ~s(#source-search-input[value="nothing-matches"]))
      assert has_element?(view, ~s(button[aria-label="Clear search"]))

      click_element(view, "#source-search-empty button", "Clear Search")

      assert render_element(view, "#source-table") =~ "Zebra source"
      refute has_element?(view, "#source-search-empty")
      refute has_element?(view, ~s(button[aria-label="Clear search"]))
      assert summary_text(view) == ""
    end

    test "clears the search from the field action", %{conn: conn} do
      source_fixture(custom_name: "Zebra source")
      source_fixture(custom_name: "Other source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      refute search(view, "zebra") =~ "Other source"

      click_element(view, ~s(button[aria-label="Clear search"]))

      assert render_element(view, "#source-table") =~ "Other source"
    end

    test "treats a blank term as no search", %{conn: conn} do
      source_fixture(custom_name: "Zebra source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert search(view, "   ") =~ "Zebra source"
      assert summary_text(view) == ""
      refute has_element?(view, ~s(button[aria-label="Clear search"]))
    end

    test "keeps the search while sorting by a media total and switching views", %{conn: conn} do
      zebra_a = source_fixture(custom_name: "Zebra A")
      zebra_b = source_fixture(custom_name: "Zebra B")
      source_fixture(custom_name: "Other source")
      media_item_fixture(source_id: zebra_b.id, media_filepath: nil)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      search(view, "zebra")
      click_element(view, "th button", "Pending")
      click_element(view, "th button", "Pending")

      assert render_element(view, "tbody tr:first-child") =~ zebra_b.custom_name
      assert render_element(view, "tbody tr:last-child") =~ zebra_a.custom_name
      refute render(view) =~ "Other source"

      click_element(view, ~s([data-view-toggle="grid"]))

      grid = render_element(view, "#source-poster-grid")
      assert grid =~ zebra_a.custom_name
      assert grid =~ zebra_b.custom_name
      refute grid =~ "Other source"
    end

    test "returns to the first page and clears the selection", %{conn: conn} do
      source_fixture(custom_name: "Zebra A")
      second = source_fixture(custom_name: "Zebra B")
      session = Map.put(create_session(), "results_per_page", 1)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      click_element(view, "button.pagination-next")
      render_click(view, "toggle_source_selection", %{"id" => to_string(second.id)})
      assert has_element?(view, ~s(#selected-source-actions[data-selected-count="1"]))

      search(view, "zebra")

      assert text(render_element(view, "nav[aria-label=Pagination]")) =~ "Page 1 of 2"
      assert render_element(view, "#source-table") =~ "Zebra A"
      assert has_element?(view, ~s(#selected-source-actions[data-selected-count="0"]))
    end

    test "starts from a trimmed search term in the session", %{conn: conn} do
      source_fixture(custom_name: "Zebra source")
      source_fixture(custom_name: "Other source")
      session = Map.put(create_session(), "initial_search_term", "  zebra  ")

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: session)

      assert html =~ "Zebra source"
      refute html =~ "Other source"
      assert has_element?(view, ~s(#source-search-input[value="zebra"]))
    end

    test "hides the search when the tab has no sources", %{conn: conn} do
      source_fixture(custom_name: "Channel only")
      session = Map.put(create_session(), "source_type", "videos")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      refute has_element?(view, "#source-search-form")
      assert has_element?(view, "h3", "No individual videos yet")
    end

    test "normalizes search terms" do
      assert IndexTableLive.normalize_search_term(nil) == nil
      assert IndexTableLive.normalize_search_term(" ") == nil
      assert IndexTableLive.normalize_search_term(" zebra ") == "zebra"
      assert IndexTableLive.normalize_search_term(String.duplicate("a", 250)) == String.duplicate("a", 200)
    end
  end

  describe "view mode defaults" do
    test "opens the poster grid by default", %{conn: conn} do
      source_fixture(custom_name: "Default grid source")

      session = %{
        "initial_sort_key" => :custom_name,
        "initial_sort_direction" => :asc,
        "results_per_page" => 10
      }

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: session)

      assert html =~ ~s(data-view="poster-grid")
      assert has_element?(view, "#source-poster-grid")
      refute has_element?(view, "#source-table")
    end

    test "renders the table when the initial view mode is table", %{conn: conn} do
      source_fixture()

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert html =~ ~s(data-view="table")
      assert has_element?(view, "#source-table")
      refute has_element?(view, "#source-poster-grid")
    end

    test "falls back to the grid for an unknown initial view mode", %{conn: conn} do
      source_fixture()

      session = Map.put(create_session(), "initial_view_mode", "sideways")
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      assert has_element?(view, "#source-poster-grid")
      refute has_element?(view, "#source-table")
    end
  end

  defp click_element(view, selector, text_filter \\ nil) do
    view
    |> element(selector, text_filter)
    |> render_click()
  end

  defp render_element(view, selector) do
    view
    |> element(selector)
    |> render()
  end

  defp search(view, term) do
    view
    |> element("#source-search-form")
    |> render_change(%{"q" => term})
  end

  defp summary_text(view), do: view |> render_element("#source-search-summary") |> text()

  defp text(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.replace("&amp;", "&")
    |> String.trim()
  end

  defp retention_form(source), do: "#retention-form-#{source.id}-source-retention-#{source.id}"

  defp row_retention(view, source) do
    view
    |> element("#source-retention-#{source.id}")
    |> render()
  end

  defp cell_text(view, selector) do
    view
    |> render_element(selector)
    |> String.replace(~r/<[^>]*>/, "")
    |> String.trim()
  end

  defp ordered_source_ids(html) do
    ~r/data-source-id="(\d+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [id] -> String.to_integer(id) end)
    |> Enum.dedup()
  end

  defp source_ids(html) do
    ~r/data-source-id="(\d+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [id] -> String.to_integer(id) end)
    |> MapSet.new()
  end

  defp create_session do
    %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "initial_view_mode" => :table,
      "results_per_page" => 10
    }
  end

  describe "source action controls" do
    test "row menus run their actions without leaving the list", %{conn: conn} do
      source = source_fixture(custom_name: "Action source")

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: create_session())

      for action <- ["start", "pause", "stop"] do
        assert has_element?(
                 view,
                 ~s(#source-table button[phx-click="source_switch"][phx-value-action="#{action}"][phx-value-id="#{source.id}"])
               )
      end

      refute html =~ ~s(action="/sources/#{source.id}/start_all")
      assert has_element?(view, ~s(button[aria-label="More actions for Action source"]))
      refute html =~ "data-confirm"

      # Delete Source opens the shared delete dialog for just this source.
      view |> element(~s(#source-table button[aria-label="Delete Action source"])) |> render_click()
      assert has_element?(view, "#delete-selected-sources-modal-title", "Delete Action source?")
      refute has_element?(view, "#source-table .theme-dropdown-option button", "Delete Source")
      assert has_element?(view, "#delete-selected-sources input[name='source_ids[]'][value='#{source.id}']")
      assert has_element?(view, "#delete-selected-sources button[name=delete_files]", "Delete Source + Files")

      for label <- ["Start All", "Pause All", "Stop All"] do
        assert has_element?(view, ~s(#source-table button[aria-label="#{label}: Action source"]))
      end
    end

    test "a row's actions report a notice and keep the list in place", %{conn: conn} do
      source = source_fixture(custom_name: "Live actions", download_media: true)
      media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())
      job = ~s(#source-table button[phx-click="source_job"][phx-value-id="#{source.id}"])

      view |> element(~s(#{job}[phx-value-action="force_index"])) |> render_click()
      assert render(view) =~ "Force Index for 1 source"

      view
      |> element(~s(#source-table button[phx-click="source_automatic_downloads"][phx-value-id="#{source.id}"]))
      |> render_click()

      refute Repo.reload!(source).download_media
      assert render(view) =~ "Automatic downloads disabled for Live actions."

      view
      |> element(~s(#source-table button[phx-click="source_automatic_downloads"][phx-value-enabled="true"]))
      |> render_click()

      assert Repo.reload!(source).download_media

      view
      |> element(
        ~s(#source-table button[phx-click="source_switch"][phx-value-action="start"][phx-value-id="#{source.id}"])
      )
      |> render_click()

      assert render(view) =~ "Live actions: downloads started."
    end

    test "keeps the selection checkbox accessible without visible Select label text", %{conn: conn} do
      source_fixture(custom_name: "Selectable source")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert has_element?(view, "input[aria-label='Select Selectable source']")
      assert has_element?(view, "label > span.sr-only", "Select")
      refute has_element?(view, "label > span:not(.sr-only)", "Select")
    end

    test "keeps the Individual Videos tab for row actions and deletes", %{conn: conn} do
      source = source_fixture(custom_name: "Video source", collection_type: :video)
      session = Map.merge(create_session(), %{"source_type" => "videos"})

      {:ok, view, html} = live_isolated(conn, IndexTableLive, session: session)

      assert has_element?(view, ~s(button[phx-click="source_switch"][phx-value-id="#{source.id}"]))
      refute html =~ ~s(action="/sources/#{source.id}/start_all")
      assert html =~ ~s(name="return_to" value="/sources?type=videos")
    end
  end

  # Lets an armed bulk action accept its confirming click, as it does once the double-click window passes.
  defp ripen_armed(view) do
    ref = :sys.get_state(view.pid).socket.assigns.armed |> elem(2)
    send(view.pid, {:ripen_bulk, ref})
  end
end
