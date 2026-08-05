defmodule PinchflatWeb.Sources.SourceLive.IndexTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Sources.Source
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive

  describe "initial rendering" do
    test "lists all sources", %{conn: conn} do
      source = source_fixture()

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

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(3)") == "2"
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(4)") == "0"
    end

    test "names the collection type of each source", %{conn: conn} do
      source_fixture(custom_name: "A_Channel", collection_type: "channel")
      source_fixture(custom_name: "B_Playlist", collection_type: "playlist")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(2)") =~ "Channel"
      assert cell_text(view, "tbody tr:last-child td:nth-of-type(2)") =~ "Playlist"
    end

    test "shows pending and downloaded counts for sources with downloaded media", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_filepath: nil})
      media_item_fixture(%{source_id: source.id})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      assert cell_text(view, "tbody tr:first-child td:nth-of-type(3)") == "1"
      assert cell_text(view, "tbody tr:first-child td:nth-of-type(4)") == "1"
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
      click_element(view, "th", "Name")

      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source2.custom_name
    end

    test "clicking a different row will sort by that attribute", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_A", enabled: true)
      source2 = source_fixture(custom_name: "Source_A", enabled: false)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      # Click the row to change the sort field
      click_element(view, "th", "Enabled?")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name

      # Click the row to again change the sort direcation
      click_element(view, "th", "Enabled?")
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

<<<<<<< HEAD
=======
  describe "when sorting by the other columns" do
    test "sorts by pending count", %{conn: conn} do
      source1 = source_fixture(custom_name: "Has_Pending")
      source2 = source_fixture(custom_name: "No_Pending")
      media_item_fixture(%{source_id: source1.id, media_filepath: nil})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th", "Pending")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end

    test "sorts by downloaded count", %{conn: conn} do
      source1 = source_fixture(custom_name: "Has_Downloads")
      source2 = source_fixture(custom_name: "No_Downloads")
      media_item_fixture(%{source_id: source1.id})

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th", "Downloaded")

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
      click_element(view, "th", "Size")
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name

      click_element(view, "th", "Size")
      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
    end

    test "sorts by collection type", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_A", collection_type: "channel")
      source2 = source_fixture(custom_name: "Source_B", collection_type: "playlist")

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th", "Type")

      assert render_element(view, "tbody tr:first-child") =~ source1.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source2.custom_name

      click_element(view, "th", "Type")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end

    test "sorts by media profile name without case sensitivity", %{conn: conn} do
      profile1 = media_profile_fixture(name: "zebra profile")
      profile2 = media_profile_fixture(name: "Apple Profile")
      source1 = source_fixture(custom_name: "Source_Z", media_profile_id: profile1.id)
      source2 = source_fixture(custom_name: "Source_A", media_profile_id: profile2.id)

      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      click_element(view, "th", "Media Profile")

      assert render_element(view, "tbody tr:first-child") =~ source2.custom_name
      assert render_element(view, "tbody tr:last-child") =~ source1.custom_name
    end
  end

>>>>>>> 7e8331f (feat-fix: show whether a source is a channel / playlist; UI fixes)
  describe "when testing pagination" do
    test "moving to the next page loads new records", %{conn: conn} do
      source1 = source_fixture(custom_name: "Source_A")
      source2 = source_fixture(custom_name: "Source_B")

      session = Map.merge(create_session(), %{"results_per_page" => 1})
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

      assert render_element(view, "tbody") =~ source1.custom_name
      refute render_element(view, "tbody") =~ source2.custom_name

      click_element(view, "span.pagination-next")

      refute render_element(view, "tbody") =~ source1.custom_name
      assert render_element(view, "tbody") =~ source2.custom_name
    end
  end

  describe "when testing the enable toggle" do
    test "updates the source's enabled status", %{conn: conn} do
      source = source_fixture(enabled: true)
      {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: create_session())

      view
      |> element("#source_enable_toggle_source_#{source.id}_enabled_form")
      |> render_change(%{source: %{"enabled" => false}})

      assert %{enabled: false} = Repo.get!(Source, source.id)
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

  defp create_session do
    %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "results_per_page" => 10
    }
  end
end
