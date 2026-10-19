defmodule PinchflatWeb.BulkSourceProfileTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive

  test "assigns new media profile to selected sources", %{conn: conn} do
    profile_a = media_profile_fixture(name: "Profile Alpha")
    profile_b = media_profile_fixture(name: "Profile Beta")
    source_1 = source_fixture(media_profile_id: profile_a.id)
    source_2 = source_fixture(media_profile_id: profile_a.id)
    untouched = source_fixture(media_profile_id: profile_a.id)

    conn =
      post(conn, "/sources/assign_profile_selected", %{
        "source_ids" => ["#{source_1.id}", "#{source_2.id}"],
        "media_profile_id" => "#{profile_b.id}"
      })

    assert redirected_to(conn) == "/sources"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Media profile updated for 2 sources."

    assert Repo.reload!(source_1).media_profile_id == profile_b.id
    assert Repo.reload!(source_2).media_profile_id == profile_b.id
    assert Repo.reload!(untouched).media_profile_id == profile_a.id
  end

  test "missing or invalid profile rejects the selection", %{conn: conn} do
    profile = media_profile_fixture()
    source = source_fixture(media_profile_id: profile.id)
    deleted_profile = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())

    for bad_profile_id <- [
          nil,
          "",
          "invalid",
          "999999",
          "#{deleted_profile.id}",
          "999999999999999999999999",
          %{"id" => "1"},
          "-1",
          "0"
        ] do
      response =
        post(conn, "/sources/assign_profile_selected", %{
          "source_ids" => ["#{source.id}"],
          "media_profile_id" => bad_profile_id
        })

      assert redirected_to(response) == "/sources"
      assert Phoenix.Flash.get(response.assigns.flash, :error)
      assert Repo.reload!(source).media_profile_id == profile.id
    end
  end

  test "invalid source selection rejects and changes nothing", %{conn: conn} do
    profile_a = media_profile_fixture()
    profile_b = media_profile_fixture()
    source = source_fixture(media_profile_id: profile_a.id)
    removed = source_fixture(media_profile_id: profile_a.id, marked_for_deletion_at: DateTime.utc_now())

    for ids <- [
          nil,
          "1",
          [],
          ["invalid"],
          ["-1"],
          ["#{source.id}", "999999"],
          ["#{source.id}", "#{removed.id}"],
          List.duplicate("#{source.id}", 101)
        ] do
      response =
        post(conn, "/sources/assign_profile_selected", %{
          "source_ids" => ids,
          "media_profile_id" => "#{profile_b.id}"
        })

      assert redirected_to(response) == "/sources"
      assert Phoenix.Flash.get(response.assigns.flash, :error)
      assert Repo.reload!(source).media_profile_id == profile_a.id
    end
  end

  test "LiveView toolbar renders profile selection and options", %{conn: conn} do
    profile_a = media_profile_fixture(name: "Quality Profile 1")
    profile_b = media_profile_fixture(name: "Quality Profile 2")
    deleted = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())
    source = source_fixture(media_profile_id: profile_a.id)

    session = %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "initial_view_mode" => :table,
      "results_per_page" => 10
    }

    {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)
    refute has_element?(view, "#selected-source-profile")
    render_click(view, "select_page")
    refute has_element?(view, "#selected-source-profile button[disabled]")

    assert has_element?(
             view,
             "#selected-source-media-profile-options button[data-value='#{profile_a.id}']",
             "Quality Profile 1"
           )

    assert has_element?(
             view,
             "#selected-source-media-profile-options button[data-value='#{profile_b.id}']",
             "Quality Profile 2"
           )

    refute has_element?(view, "#selected-source-media-profile-options button[data-value='#{deleted.id}']")
    assert has_element?(view, "#selected-source-profile input[name='source_ids[]'][value='#{source.id}']")

    render_click(view, "clear_selection")
    refute has_element?(view, "#selected-source-profile")
  end

  test "profile assignment keeps existing files and schedules metadata only for changes", %{conn: conn} do
    profile_a = media_profile_fixture()
    profile_b = media_profile_fixture()
    source = source_fixture(media_profile_id: profile_a.id)
    item = media_item_with_attachments(%{source_id: source.id})
    bytes = File.read!(item.media_filepath)
    Repo.delete_all(Oban.Job)
    params = %{"source_ids" => ["#{source.id}"], "media_profile_id" => "#{profile_b.id}"}
    response = post(conn, "/sources/assign_profile_selected", params)
    assert Phoenix.Flash.get(response.assigns.flash, :info)
    assert File.read!(item.media_filepath) == bytes
    assert Repo.reload!(item).media_filepath == item.media_filepath
    assert Repo.reload!(source).download_subdirectory == source.download_subdirectory
    assert Repo.aggregate(Oban.Job, :count) == 1
    post(conn, "/sources/assign_profile_selected", params)
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "a failed profile update rolls back all settings and metadata jobs", %{conn: conn} do
    profile_a = media_profile_fixture()
    profile_b = media_profile_fixture()
    source = source_fixture(media_profile_id: profile_a.id)
    invalid = source_fixture(media_profile_id: profile_a.id)
    Repo.update_all(from(s in Pinchflat.Sources.Source, where: s.id == ^invalid.id), set: [custom_name: ""])
    Repo.delete_all(Oban.Job)

    response =
      post(conn, "/sources/assign_profile_selected", %{
        "source_ids" => ["#{source.id}", "#{invalid.id}"],
        "media_profile_id" => "#{profile_b.id}"
      })

    assert Phoenix.Flash.get(response.assigns.flash, :error)
    assert Repo.reload!(source).media_profile_id == profile_a.id
    assert Repo.reload!(invalid).media_profile_id == profile_a.id
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
