defmodule PinchflatWeb.BulkSourcePauseTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Repo
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive

  test "pauses selected sources, cancels replacements and keeps monitoring and other work", %{conn: conn} do
    source = source_fixture()
    idle = source_fixture()
    untouched = source_fixture()
    item = media_item_with_attachments(%{source_id: source.id})
    original = File.read!(item.media_filepath)
    {:ok, task} = MediaDownloadWorker.kickoff_with_task(item, %{force: true})
    Repo.update_all(from(j in Oban.Job, where: j.id == ^task.job_id), set: [state: "executing"])
    other_item = media_item_fixture(%{source_id: untouched.id, media_filepath: nil})
    {:ok, other_task} = MediaDownloadWorker.kickoff_with_task(other_item)

    conn = post(conn, "/sources/pause_selected", %{"source_ids" => ["#{source.id}", "#{idle.id}"]})

    assert redirected_to(conn) == "/sources"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Downloads paused for 2 sources."

    for selected <- [source, idle] do
      updated = Repo.reload!(selected)
      refute updated.download_media
      assert updated.enabled == selected.enabled
      assert updated.index_frequency_minutes == selected.index_frequency_minutes
    end

    assert Repo.reload!(untouched).download_media
    assert Repo.get!(Oban.Job, task.job_id).state == "cancelled"
    assert Repo.get!(Oban.Job, other_task.job_id).state == "available"
    assert File.read!(item.media_filepath) == original
  end

  test "invalid or stale selections change nothing", %{conn: conn} do
    source = source_fixture()
    removed = source_fixture(marked_for_deletion_at: DateTime.utc_now())

    for ids <- [
          nil,
          "1",
          %{"id" => "1"},
          [],
          ["invalid"],
          ["-1"],
          ["999999999999999999999999999999999999999"],
          ["#{source.id}", "999999"],
          ["#{source.id}", "#{removed.id}"],
          List.duplicate("#{source.id}", 101)
        ] do
      response = post(conn, "/sources/pause_selected", %{"source_ids" => ids})
      assert redirected_to(response) == "/sources"
      assert Phoenix.Flash.get(response.assigns.flash, :error)
      assert Repo.reload!(source).download_media
    end
  end

  test "duplicate IDs pause one source once", %{conn: conn} do
    source = source_fixture()
    response = post(conn, "/sources/pause_selected", %{"source_ids" => ["#{source.id}", "#{source.id}"]})
    assert Phoenix.Flash.get(response.assigns.flash, :info) == "Downloads paused for 1 source."
    refute Repo.reload!(source).download_media
  end

  test "a source whose profile is being deleted rejects the whole selection", %{conn: conn} do
    source = source_fixture()
    unavailable = source_fixture()

    unavailable
    |> Repo.preload(:media_profile)
    |> Map.fetch!(:media_profile)
    |> Ecto.Changeset.change(marked_for_deletion_at: DateTime.truncate(now(), :second))
    |> Repo.update!()

    response = post(conn, "/sources/pause_selected", %{"source_ids" => ["#{source.id}", "#{unavailable.id}"]})
    assert Phoenix.Flash.get(response.assigns.flash, :error)
    assert Repo.reload!(source).download_media
    assert Repo.reload!(unavailable).download_media
  end

  test "a failed update rolls back the selection before cancelling work", %{conn: conn} do
    source = source_fixture()
    invalid = source_fixture()
    Repo.update_all(from(s in Pinchflat.Sources.Source, where: s.id == ^invalid.id), set: [custom_name: ""])
    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
    {:ok, task} = MediaDownloadWorker.kickoff_with_task(item)

    response = post(conn, "/sources/pause_selected", %{"source_ids" => ["#{source.id}", "#{invalid.id}"]})
    assert Phoenix.Flash.get(response.assigns.flash, :error)
    assert Repo.reload!(source).download_media
    assert Repo.reload!(invalid).download_media
    assert Repo.get!(Oban.Job, task.job_id).state == "available"
  end

  test "selection is page-scoped, clears on sorting, and is shared between layouts", %{conn: conn} do
    first = source_fixture(custom_name: "A first")
    second = source_fixture(custom_name: "B second")

    session = %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "initial_view_mode" => :table,
      "results_per_page" => 1
    }

    {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)
    assert has_element?(view, "#pause-selected-sources button[disabled]")

    render_click(view, "select_page")
    assert has_element?(view, "#pause-selected-sources input[name='source_ids[]'][value='#{first.id}']")
    refute has_element?(view, "#pause-selected-sources input[value='#{second.id}']")
    render_click(view, "toggle_source_selection", %{"id" => "#{second.id}"})
    refute has_element?(view, "#pause-selected-sources input[value='#{second.id}']")

    render_click(view, "view_change", %{"view" => "grid"})
    assert has_element?(view, "#source-select-grid-#{first.id}[checked]")
    render_click(view, "page_change", %{"direction" => "inc"})
    assert has_element?(view, "#pause-selected-sources button[disabled]")
    render_click(view, "select_page")
    assert has_element?(view, "#pause-selected-sources input[value='#{second.id}']")
    render_click(view, "clear_selection")
    assert has_element?(view, "#pause-selected-sources button[disabled]")
    render_click(view, "toggle_source_selection", %{"id" => "#{second.id}"})
    assert has_element?(view, "#pause-selected-sources input[value='#{second.id}']")
    render_click(view, "sort_update", %{"sort_key" => "custom_name"})
    assert has_element?(view, "#pause-selected-sources button[disabled]")
  end
end
