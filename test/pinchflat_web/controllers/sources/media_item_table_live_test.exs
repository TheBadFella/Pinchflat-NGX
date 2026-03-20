defmodule PinchflatWeb.Sources.MediaItemTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias PinchflatWeb.Sources.MediaItemTableLive
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Tasks

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn, source: source} do
      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Nothing Here!"
      refute html =~ "Showing"
    end

    test "shows records when present", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Showing"
      assert html =~ "Title"
      assert html =~ media_item.title
    end
  end

  describe "media_state" do
    test "shows pending media when pending", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ pending_media_item.title
      refute html =~ downloaded_media_item.title
    end

    test "shows downloaded media when downloaded", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows records that aren't pending or downloaded when other", %{conn: conn} do
      media_profile = media_profile_fixture(shorts_behaviour: :exclude)
      source = source_fixture(media_profile_id: media_profile.id)

      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      other_media_item = media_item_fixture(source_id: source.id, media_filepath: nil, short_form_content: true)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ other_media_item.title
      refute html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows 'Prevent Download' column when other", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, prevent_download: true, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ "Prevent Download?"
      assert html =~ "Excluded Reason"
      assert html =~ "Prevented"
    end

    test "shows cutoff reason for excluded media", %{conn: conn} do
      source = source_fixture(download_cutoff_date: ~D[2024-01-01])

      excluded_media_item =
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          uploaded_at: ~U[2023-01-01 00:00:00Z]
        )

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ excluded_media_item.title
      assert html =~ "Before cutoff"
    end

    test "shows phase text for active downloads before total size is known", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      {:ok, _task} =
        Tasks.update_task_progress(task, %{
          progress_percent: 0.0,
          progress_status: "Waiting for transfer to start"
        })

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ "Waiting for transfer to start"
    end

    test "shows wrapped full errors inline", %{conn: conn, source: source} do
      media_item =
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          last_error: "ERROR: unable to download video data: HTTP Error 429: Too Many Requests"
        )

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ media_item.title
      assert html =~ media_item.last_error
    end
  end

  defp create_session(source, media_state \\ "pending") do
    %{"source_id" => source.id, "media_state" => media_state}
  end
end
