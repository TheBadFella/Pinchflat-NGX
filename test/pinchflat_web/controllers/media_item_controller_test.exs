defmodule PinchflatWeb.MediaItemControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.Repo

  describe "automatic deletion guidance" do
    test "warns before downloading an unprotected video before cutoff", %{conn: conn} do
      source = Pinchflat.SourcesFixtures.source_fixture(download_cutoff_date: ~D[2026-10-17], retention_period_days: 10)
      item = media_item_fixture(source_id: source.id, uploaded_at: ~U[2026-10-15 12:00:00Z], media_filepath: nil)

      html = conn |> get(~p"/sources/#{source.id}/media/#{item}") |> html_response(200)

      assert html =~ "This video was published on 2026-10-15"
      assert html =~ "download cutoff date of 2026-10-17"
      assert html =~ "next scheduled cleanup"
      assert html =~ "Protect this video"
      assert html =~ ~p"/sources/#{source.id}/media/#{item}/edit#media_item_prevent_culling"
    end

    test "shows protection instead of a cutoff warning after saving it", %{conn: conn} do
      source = Pinchflat.SourcesFixtures.source_fixture(download_cutoff_date: ~D[2026-10-17])
      item = media_item_fixture(source_id: source.id, uploaded_at: ~U[2026-10-15 12:00:00Z])

      response = put(conn, ~p"/sources/#{source.id}/media/#{item}", media_item: %{prevent_culling: true})
      assert redirected_to(response) == ~p"/sources/#{source.id}/media/#{item}"
      assert Repo.reload!(item).prevent_culling

      html = conn |> get(~p"/sources/#{source.id}/media/#{item}") |> html_response(200)
      assert html =~ "Protected from automatic deletion"
      refute html =~ "This video was published on"
      refute html =~ ~s(id="automatic-deletion")
      assert html =~ "Change deletion protection"
    end

    test "the cutoff day is included and does not show the warning", %{conn: conn} do
      source = Pinchflat.SourcesFixtures.source_fixture(download_cutoff_date: ~D[2026-10-17])
      item = media_item_fixture(source_id: source.id, uploaded_at: ~U[2026-10-17 00:00:00Z])

      html = conn |> get(~p"/sources/#{source.id}/media/#{item}") |> html_response(200)
      refute html =~ "This video was published on"
      refute html =~ ~s(id="automatic-deletion")
      refute html =~ ~s(id="automatic-deletion-status")
      assert html =~ "Protect from automatic deletion"
    end

    test "a source without a cutoff offers protection through Actions without a warning panel", %{conn: conn} do
      item = media_item_fixture()
      html = conn |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)

      refute html =~ ~s(id="automatic-deletion")
      refute html =~ ~s(id="automatic-deletion-status")
      assert html =~ "Protect from automatic deletion"
    end
  end

  describe "show media" do
    setup [:create_media_item]

    test "renders the page", %{conn: conn, media_item: media_item} do
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      assert html_response(conn, 200) =~ "#{media_item.title}"
    end

    test "renders the page when the media item has no description", %{conn: conn} do
      media_item = media_item_with_attachments(%{description: nil})
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      assert html_response(conn, 200) =~ "#{media_item.title}"
    end
  end

  describe "watch window" do
    test "incomplete and failed checks both explain why replacement is blocked", %{conn: conn} do
      profile = media_profile_fixture() |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
      source = source_fixture(%{media_profile_id: profile.id})
      item = media_item_with_attachments(%{source_id: source.id})
      {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      public = %Observation{backend: :test, observed_at: now, availability: :public, duration_seconds: 120, livestream: false}
      {:ok, _} = MediaWatch.record_observation(watch, public)
      incomplete = %{public | availability: :private, duration_seconds: nil, observed_at: DateTime.add(now, 60)}
      {:ok, %{watch: held}} = MediaWatch.record_observation(watch, incomplete)
      assert held.last_error_at
      assert MediaWatch.replacement_blocked?(item.id)

      html = conn |> get(~p"/sources/#{source.id}/media/#{item}") |> html_response(200)
      assert html =~ "The latest remote check was inconclusive. Automatic replacement is blocked."
      assert html =~ "Last verified check"
      assert html =~ "Last inconclusive check"
      assert html =~ "private"
      assert html =~ "120 seconds"
      refute html =~ "The latest remote check failed"

      {:ok, %{watch: failed}} =
        MediaWatch.record_observation(watch, Observation.unknown(:yt_dlp, :timeout, DateTime.add(now, 120)))

      assert failed.last_error_at
      assert MediaWatch.replacement_blocked?(item.id)
      failed_html = conn |> recycle() |> get(~p"/sources/#{source.id}/media/#{item}") |> html_response(200)
      assert failed_html =~ "The latest remote check was inconclusive. Automatic replacement is blocked."
      assert failed_html =~ "Last inconclusive check"
    end

    test "shows the fixed window, remote baseline and saved-original state", %{conn: conn} do
      on_exit(fn -> File.rm_rf(Pinchflat.MediaWatch.OriginalArchive.root()) end)

      profile =
        media_profile_fixture()
        |> Ecto.Changeset.change(watch_window_days: 14)
        |> Repo.update!()

      source = source_fixture(%{media_profile_id: profile.id})
      item = media_item_with_attachments(%{source_id: source.id})
      File.write!(item.media_filepath, "first artifact")

      {:ok, watch} = Pinchflat.MediaWatchFixtures.enroll_approved_watch(item, Repo.preload(source, :media_profile))
      {:ok, _published} = MediaWatch.archive_original(watch, Repo.preload(item, :metadata))

      {:ok, watch} =
        watch
        |> Ecto.Changeset.change(
          baseline_upstream_duration_seconds: 120,
          hold_reason: "watch change: duration",
          current_visibility: "unlisted",
          confirmed_state: "suspected",
          suspected_kind: "duration",
          last_success_at: ~U[2026-10-25 12:00:00Z]
        )
        |> Repo.update()

      html = conn |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)

      assert html =~ "Watch window"
      document = LazyHTML.from_document(html)
      banner = LazyHTML.query(document, "#watch-window.theme-status-card-warning")
      assert LazyHTML.attribute(banner, "id") == ["watch-window"]
      details = LazyHTML.query(document, "#watch-details")
      assert LazyHTML.attribute(details, "id") == ["watch-details"]
      assert LazyHTML.attribute(details, "open") == []
      assert html =~ Calendar.strftime(watch.started_at, "%Y-%m-%d %H:%M")
      assert html =~ Calendar.strftime(watch.ends_at, "%Y-%m-%d %H:%M")
      assert html =~ "Remote duration baseline"
      assert html =~ "120 seconds"
      assert html =~ "Local playback duration"
      assert html =~ "Remote visibility"
      assert html =~ "unlisted"
      assert html =~ "suspected change"
      assert html =~ "Change type"
      assert html =~ "duration"
      assert html =~ "Saved original retained separately from the current file"
      assert html =~ ".pinchflat-originals/#{watch.id}/manifest.json"
      assert html =~ "Size"
      assert html =~ "Automatic replacement is blocked"

      watch |> Ecto.Changeset.change(confirmed_state: "confirmed") |> Repo.update!()
      html = conn |> recycle() |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)

      assert html =~ "confirmed change"
      assert html =~ "Change type"
      assert html =~ "duration"
      refute html =~ "The suspected difference"
      refute html =~ "replacement stays blocked until a later check matches it"

      watch
      |> Ecto.Changeset.change(
        ends_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second),
        hold_reason: nil
      )
      |> Repo.update!()
      expired_html = conn |> recycle() |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)
      assert expired_html =~ "Saved original retained separately from the current file"
      assert expired_html =~ "The watch has ended; automatic retention may remove the current file."
      refute expired_html =~ "Protected from replacement and automatic retention"
    end

    test "does not show watch details for an unenrolled item", %{conn: conn} do
      item = media_item_fixture()

      html = conn |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)

      refute html =~ ~s(id="watch-window")
    end

    test "renders watch history timeline and current duration with delta", %{conn: conn} do
      profile =
        media_profile_fixture()
        |> Ecto.Changeset.change(watch_window_days: 14)
        |> Repo.update!()

      source = source_fixture(%{media_profile_id: profile.id})
      item = media_item_with_attachments(%{source_id: source.id, duration_seconds: 9})

      {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))

      {:ok, watch} =
        watch
        |> Ecto.Changeset.change(
          baseline_upstream_duration_seconds: 9,
          current_upstream_duration_seconds: 4,
          confirmed_upstream_duration_seconds: 4,
          hold_reason: "watch change: duration",
          confirmed_state: "confirmed",
          suspected_kind: "duration"
        )
        |> Repo.update()

      {:ok, _event} =
        MediaWatch.record_event(watch, "duration", "duration:9->4:transition:1", %{
          old_value: "9",
          new_value: "4"
        })

      html = conn |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)

      assert html =~ "Remote duration baseline"
      assert html =~ "9 seconds"
      assert html =~ "Current remote duration"
      assert html =~ "4 seconds"
      assert html =~ "-5s"
      assert html =~ "Upstream video duration changed from 9s to 4s"
      assert html =~ "Automatic replacement is blocked so the modified video does not overwrite your original file"
      assert html =~ "Watch history"
      assert html =~ "Timestamp"
      refute html =~ "Timestamp (UTC)"
      assert html =~ "Duration edited"
      assert html =~ "9s → 4s"
      assert html =~ "pending"
    end

    test "renders watch details and history in compose-defined timezone", %{conn: conn} do
      profile =
        media_profile_fixture()
        |> Ecto.Changeset.change(watch_window_days: 14)
        |> Repo.update!()

      source = source_fixture(%{media_profile_id: profile.id})
      item = media_item_with_attachments(%{source_id: source.id, duration_seconds: 9})

      {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))

      observed = ~U[2026-10-26 17:58:58Z]

      {:ok, _event} =
        MediaWatch.record_event(watch, "duration", "duration:9->4:transition:1", %{
          old_value: "9",
          new_value: "4",
          observed_at: observed
        })

      original_timezone = Application.get_env(:pinchflat, :timezone)
      on_exit(fn -> Application.put_env(:pinchflat, :timezone, original_timezone) end)

      for {timezone, expected} <- [
            {"America/Regina", "2026-10-26 11:58:58"},
            {"UTC", "2026-10-26 17:58:58"},
            {nil, "2026-10-26 17:58:58"},
            {"Invalid/Timezone", "2026-10-26 17:58:58"}
          ] do
        Application.put_env(:pinchflat, :timezone, timezone)
        html = conn |> get(~p"/sources/#{item.source_id}/media/#{item}") |> html_response(200)

        assert html =~ "Timestamp"
        refute html =~ "Timestamp (UTC)"
        assert html =~ expected
      end
    end
  end

  describe "edit media" do
    setup [:create_media_item]

    test "renders form for editing chosen media_item", %{conn: conn, media_item: media_item} do
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}/edit")

      assert html_response(conn, 200) =~ "Editing"
    end
  end

  describe "update media" do
    setup [:create_media_item]

    test "redirects when data is valid", %{conn: conn, media_item: media_item} do
      update_attrs = %{title: "New Title"}

      conn = put(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: update_attrs)
      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item}"

      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}")
      assert html_response(conn, 200) =~ update_attrs[:title]
    end

    test "renders errors when data is invalid", %{conn: conn, media_item: media_item} do
      conn = put(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: %{title: nil})

      assert html_response(conn, 200) =~ "Editing"
    end
  end

  describe "delete media" do
    setup do
      media_item = media_item_with_attachments()
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      %{media_item: media_item}
    end

    test "the media item not is deleted", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      assert Repo.reload!(media_item)
    end

    test "the files are deleted", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      refute File.exists?(media_item.media_filepath)
    end

    test "redirects to the source page", %{conn: conn, media_item: media_item} do
      conn = delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}"
    end

    test "doesn't prevent re-download by default", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      media_item = Repo.reload(media_item)

      refute media_item.prevent_download
    end

    test "can optionally prevent re-download", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}?prevent_download=true")

      media_item = Repo.reload(media_item)

      assert media_item.prevent_download
    end
  end

  describe "force_download" do
    test "enqueues download task", %{conn: conn} do
      media_item = media_item_fixture()

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "doesn't freak out if the task is a duplicate", %{conn: conn} do
      media_item = media_item_fixture()

      MediaDownloadWorker.kickoff_with_task(media_item, %{force: true})

      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "forces a download even if one wouldn't normally run", %{conn: conn} do
      media_item = media_item_fixture(%{media_filepath: nil})

      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")

      assert [_] =
               all_enqueued(
                 worker: MediaDownloadWorker,
                 args: %{"id" => media_item.id, "force" => true, "reset_last_error" => true}
               )
    end

    test "redirects to the show page", %{conn: conn} do
      media_item = media_item_fixture()

      conn = post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item.id}"
    end
  end

  describe "streaming media" do
    test "returns 404 if the media isn't found", %{conn: conn} do
      media_item = media_item_fixture()
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 404
    end

    test "automatically sets the content type", %{conn: conn} do
      media_item = media_item_with_attachments()
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-type", "video/mp4; charset=utf-8"} in conn.resp_headers
    end

    test "sets the content length", %{conn: conn} do
      media_item = media_item_with_attachments()
      filesize = File.stat!(media_item.media_filepath).size

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-length", to_string(filesize)} in conn.resp_headers
    end
  end

  describe "streaming media when range is valid" do
    setup do
      media_item = media_item_with_attachments()

      %{media_item: media_item}
    end

    test "sets the correct status and headers", %{conn: conn, media_item: media_item} do
      filesize = File.stat!(media_item.media_filepath).size

      conn =
        conn
        |> put_req_header("range", "bytes=0-100")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 206
      assert {"content-range", "bytes 0-100/#{filesize}"} in conn.resp_headers
      assert {"content-length", "101"} in conn.resp_headers

      assert {"content-disposition",
              "inline; filename*=UTF-8''#{URI.encode(media_item.title, &URI.char_unreserved?/1)}"} in conn.resp_headers
    end

    test "streams the specified range", %{conn: conn, media_item: media_item} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-100")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert byte_size(conn.resp_body) == 101
    end

    test "supports range offsets", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      expected = String.slice(contents, 100..200)

      conn =
        conn
        |> put_req_header("range", "bytes=100-200")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == expected
    end

    test "returns as expected if the requested range is larger than the file", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      filesize = File.stat!(media_item.media_filepath).size

      conn =
        conn
        |> put_req_header("range", "bytes=0-#{filesize * 10}")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
      assert {"content-range", "bytes 0-#{filesize - 1}/#{filesize}"} in conn.resp_headers
      assert {"content-length", to_string(filesize)} in conn.resp_headers
    end

    test "supports endless ranges", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn =
        conn
        |> put_req_header("range", "bytes=0-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
    end

    test "supports endless ranges with offsets", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      {_, expected} = String.split_at(contents, 100)

      conn =
        conn
        |> put_req_header("range", "bytes=100-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == expected
    end
  end

  describe "streaming media when range is invalid or not present" do
    setup do
      media_item = media_item_with_attachments()

      %{media_item: media_item}
    end

    test "sets the correct status and headers", %{conn: conn, media_item: media_item} do
      filesize = File.stat!(media_item.media_filepath).size

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 200
      assert {"content-length", to_string(filesize)} in conn.resp_headers
      assert get_resp_header(conn, "content-range") == []

      assert {"content-disposition",
              "inline; filename*=UTF-8''#{URI.encode(media_item.title, &URI.char_unreserved?/1)}"} in conn.resp_headers
    end

    test "streams the entire file", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
    end

    test "doesn't blow up if the range header is invalid", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn =
        conn
        |> put_req_header("range", "bytes=-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 200
      assert conn.resp_body == contents
    end
  end

  describe "streaming range boundaries" do
    setup do
      item = media_item_with_attachments()
      File.write!(item.media_filepath, "0123456789")
      %{media_item: item}
    end

    test "suffix ranges return the last bytes and clamp to the file", %{conn: conn, media_item: item} do
      for {range, expected, header} <- [
            {"bytes=-3", "789", "bytes 7-9/10"},
            {"bytes=-20", "0123456789", "bytes 0-9/10"},
            {"bytes=9-", "9", "bytes 9-9/10"}
          ] do
        response = conn |> put_req_header("range", range) |> get(~p"/media/#{item.uuid}/stream")
        assert response.status == 206
        assert response.resp_body == expected
        assert get_resp_header(response, "content-range") == [header]
      end
    end

    test "unsatisfiable valid ranges return 416", %{conn: conn, media_item: item} do
      for range <- ["bytes=10-", "bytes=11-20", "bytes=-0"] do
        response = conn |> put_req_header("range", range) |> get(~p"/media/#{item.uuid}/stream")
        assert response.status == 416
        assert response.resp_body == ""
        assert get_resp_header(response, "content-range") == ["bytes */10"]
      end
    end

    test "malformed and unsupported ranges return the full file", %{conn: conn, media_item: item} do
      for range <- [
            "bytes=8-2",
            "bytes=20-10",
            "bytes=1oops-2",
            "bytes=1-2oops",
            "bytes=1-+2",
            "bytes=-",
            "bytes=0-1,4-5",
            "items=0-2"
          ] do
        response = conn |> put_req_header("range", range) |> get(~p"/media/#{item.uuid}/stream")
        assert response.status == 200
        assert response.resp_body == "0123456789"
        assert get_resp_header(response, "content-range") == []
      end
    end

    test "empty full file has no invalid content-range", %{conn: conn, media_item: item} do
      File.write!(item.media_filepath, "")
      response = get(conn, ~p"/media/#{item.uuid}/stream")
      assert response.status == 200
      assert response.resp_body == ""
      assert get_resp_header(response, "content-length") == ["0"]
      assert get_resp_header(response, "content-range") == []
    end

    test "empty file ranges are unsatisfiable", %{conn: conn, media_item: item} do
      File.write!(item.media_filepath, "")

      for range <- ["bytes=0-", "bytes=-3"] do
        response = conn |> put_req_header("range", range) |> get(~p"/media/#{item.uuid}/stream")
        assert response.status == 416
        assert get_resp_header(response, "content-range") == ["bytes */0"]
      end
    end

    test "HEAD ignores Range and returns full representation headers", %{conn: conn, media_item: item} do
      response = conn |> put_req_header("range", "bytes=0-1") |> head(~p"/media/#{item.uuid}/stream")
      assert response.status == 200
      assert get_resp_header(response, "content-length") == ["10"]
      assert get_resp_header(response, "content-range") == []
      assert response.resp_body == ""
    end

    test "If-Range falls back to the full representation without a matching validator", %{conn: conn, media_item: item} do
      response =
        conn
        |> put_req_header("range", "bytes=0-1")
        |> put_req_header("if-range", "\"old\"")
        |> get(~p"/media/#{item.uuid}/stream")

      assert response.status == 200
      assert response.resp_body == "0123456789"
      assert get_resp_header(response, "content-range") == []
    end
  end

  defp create_media_item(_) do
    media_item = media_item_fixture()
    %{media_item: media_item}
  end
end
