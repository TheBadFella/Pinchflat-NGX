defmodule PinchflatWeb.BulkSourceResumeTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive

  test "resumes selected paused sources and queues pending downloads", %{conn: conn} do
    source = source_fixture(download_media: false)
    idle = source_fixture(download_media: false)
    untouched = source_fixture(download_media: false)
    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

    conn = post(conn, "/sources/resume_selected", %{"source_ids" => ["#{source.id}", "#{idle.id}"]})

    assert redirected_to(conn) == "/sources"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Downloads resumed for 2 sources."

    for selected <- [source, idle] do
      updated = Repo.reload!(selected)
      assert updated.download_media
      assert updated.enabled == selected.enabled
      assert updated.index_frequency_minutes == selected.index_frequency_minutes
    end

    refute Repo.reload!(untouched).download_media

    # Check that pending item was queued for download
    jobs = Repo.all(from(j in Oban.Job, where: j.queue == "media_fetching"))
    assert Enum.any?(jobs, fn j -> j.args["id"] == item.id end)
  end

  test "does not queue downloads for disabled sources", %{conn: conn} do
    disabled_source = source_fixture(download_media: false, enabled: false)
    item = media_item_fixture(%{source_id: disabled_source.id, media_filepath: nil})

    conn = post(conn, "/sources/resume_selected", %{"source_ids" => ["#{disabled_source.id}"]})

    assert redirected_to(conn) == "/sources"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Downloads resumed for 1 source."

    updated = Repo.reload!(disabled_source)
    assert updated.download_media
    refute updated.enabled

    jobs = Repo.all(from(j in Oban.Job, where: j.queue == "media_fetching"))
    refute Enum.any?(jobs, fn j -> j.args["id"] == item.id end)
  end

  test "invalid or stale selections change nothing", %{conn: conn} do
    source = source_fixture(download_media: false)
    removed = source_fixture(download_media: false, marked_for_deletion_at: DateTime.utc_now())

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
      response = post(conn, "/sources/resume_selected", %{"source_ids" => ids})
      assert redirected_to(response) == "/sources"
      assert Phoenix.Flash.get(response.assigns.flash, :error)
      refute Repo.reload!(source).download_media
    end
  end

  test "duplicate IDs resume one source once", %{conn: conn} do
    source = source_fixture(download_media: false)
    response = post(conn, "/sources/resume_selected", %{"source_ids" => ["#{source.id}", "#{source.id}"]})
    assert Phoenix.Flash.get(response.assigns.flash, :info) == "Downloads resumed for 1 source."
    assert Repo.reload!(source).download_media
  end

  test "a source whose profile is being deleted rejects the whole selection", %{conn: conn} do
    source = source_fixture(download_media: false)
    unavailable = source_fixture(download_media: false)

    unavailable
    |> Repo.preload(:media_profile)
    |> Map.fetch!(:media_profile)
    |> Ecto.Changeset.change(marked_for_deletion_at: DateTime.truncate(now(), :second))
    |> Repo.update!()

    response = post(conn, "/sources/resume_selected", %{"source_ids" => ["#{source.id}", "#{unavailable.id}"]})
    assert Phoenix.Flash.get(response.assigns.flash, :error)
    refute Repo.reload!(source).download_media
    refute Repo.reload!(unavailable).download_media
  end

  test "a failed update rolls back the selection", %{conn: conn} do
    source = source_fixture(download_media: false)
    invalid = source_fixture(download_media: false)
    Repo.update_all(from(s in Pinchflat.Sources.Source, where: s.id == ^invalid.id), set: [custom_name: ""])

    response = post(conn, "/sources/resume_selected", %{"source_ids" => ["#{source.id}", "#{invalid.id}"]})
    assert Phoenix.Flash.get(response.assigns.flash, :error)
    refute Repo.reload!(source).download_media
    refute Repo.reload!(invalid).download_media
  end

  test "LiveView toolbar renders resume button and syncs with selection", %{conn: conn} do
    first = source_fixture(custom_name: "A first", download_media: false)
    second = source_fixture(custom_name: "B second", download_media: false)

    session = %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "initial_view_mode" => :table,
      "results_per_page" => 1
    }

    {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)
    refute has_element?(view, "#resume-selected-sources")

    render_click(view, "select_page")
    assert has_element?(view, "#resume-selected-sources input[name='source_ids[]'][value='#{first.id}']")
    refute has_element?(view, "#resume-selected-sources input[value='#{second.id}']")

    render_click(view, "clear_selection")
    refute has_element?(view, "#resume-selected-sources")
  end

  test "repeated resume does not duplicate downloads or change existing files", %{conn: conn} do
    source = source_fixture(download_media: false)
    pending = media_item_fixture(%{source_id: source.id, media_filepath: nil})
    downloaded = media_item_with_attachments(%{source_id: source.id})
    bytes = File.read!(downloaded.media_filepath)
    for _ <- 1..2, do: post(conn, "/sources/resume_selected", %{"source_ids" => ["#{source.id}"]})
    jobs = Repo.all(from(j in Oban.Job, where: j.queue == "media_fetching"))
    assert Enum.count(jobs, &(&1.args["id"] == pending.id)) == 1
    assert File.read!(downloaded.media_filepath) == bytes
    assert Repo.reload!(downloaded).media_filepath == downloaded.media_filepath
  end
end
