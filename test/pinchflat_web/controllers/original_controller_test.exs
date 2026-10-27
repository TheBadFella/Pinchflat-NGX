defmodule PinchflatWeb.OriginalControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.Repo

  setup do
    profile = media_profile_fixture() |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
    source = source_fixture(media_profile_id: profile.id)
    item = media_item_with_attachments(%{source_id: source.id, prevent_download: true, prevent_culling: true})
    File.write!(item.media_filepath, "first artifact")
    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
    {:ok, watch} = MediaWatch.archive_original(watch, Repo.preload(item, :metadata))
    on_exit(fn -> File.rm_rf(OriginalArchive.root()) end)
    %{item: item, watch: watch, source: source}
  end

  test "original playback supports seeking and sidecars stay inside their manifest", %{
    conn: conn,
    item: item,
    watch: watch
  } do
    conn =
      conn
      |> put_req_header("range", "bytes=0-4")
      |> get(~p"/sources/#{item.source_id}/media/#{item}/original/files/media")

    assert response(conn, 206) == "first"
    assert get_resp_header(conn, "content-range") == ["bytes 0-4/14"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    assert {:ok, files} = OriginalArchive.files(watch)

    for file <- files do
      download =
        conn
        |> recycle()
        |> get(~p"/sources/#{item.source_id}/media/#{item}/original/files/#{file["role"]}?download=true")

      assert response(download, 200)
      assert [disposition] = get_resp_header(download, "content-disposition")
      assert disposition =~ "attachment"
    end

    assert {:error, _} = OriginalArchive.file(watch, "../manifest.json")
    missing = conn |> recycle() |> get(~p"/sources/#{item.source_id}/media/#{item}/original/files/not-a-role")
    assert response(missing, 404)
  end

  test "same-size archive tampering cannot be played or downloaded", %{conn: conn, item: item, watch: watch} do
    {:ok, files} = File.ls(OriginalArchive.archive_directory(watch.id))
    saved = Path.join(OriginalArchive.archive_directory(watch.id), Enum.find(files, &String.starts_with?(&1, "media.")))
    File.write!(saved, "changed bytes!")
    assert byte_size(File.read!(saved)) == byte_size("first artifact")

    for query <- ["", "?download=true"] do
      response = get(conn, "/sources/#{item.source_id}/media/#{item.id}/original/files/media" <> query)
      assert response.status == 404
    end
  end

  test "archive routes reject another source and unauthenticated access", %{conn: conn, item: item} do
    other = source_fixture()
    assert_error_sent 404, fn -> get(conn, ~p"/sources/#{other.id}/media/#{item}/original/files/media") end

    # Exercise the same browser authentication gate as the rest of the application.
    previous = for key <- [:basic_auth_username, :basic_auth_password], do: {key, Application.get_env(:pinchflat, key)}
    Application.put_env(:pinchflat, :basic_auth_username, "archive-test")
    Application.put_env(:pinchflat, :basic_auth_password, "test-only")
    on_exit(fn -> Enum.each(previous, fn {key, value} -> Application.put_env(:pinchflat, key, value) end) end)
    response = get(conn, ~p"/sources/#{item.source_id}/media/#{item}/original/files/media")
    assert response.status == 401
  end

  test "confirmation deletes only archived files and cannot be replayed", %{conn: conn, item: item, watch: watch} do
    page = get(conn, ~p"/sources/#{item.source_id}/media/#{item}/original/release")
    html = html_response(page, 200)
    assert html =~ "permanently deleted"
    assert html =~ "manual protection settings"
    {:ok, token} = MediaWatch.release_confirmation(watch)
    result = post(conn, ~p"/sources/#{item.source_id}/media/#{item}/original/release", confirmation: token)
    assert redirected_to(result) == ~p"/sources/#{item.source_id}/media/#{item}"
    refute File.exists?(OriginalArchive.archive_directory(watch.id))
    assert File.read!(item.media_filepath) == "first artifact"
    assert Repo.reload!(item).prevent_download
    assert Repo.reload!(item).prevent_culling
    refute MediaWatch.watched?(item.id)
    refute MediaWatch.replacement_blocked?(item.id)
    assert {:ok, :unwatched} = MediaWatch.prepare_replacement(item)
    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, token)
    assert {:skip, :released} = MediaWatch.observation_eligible?(Repo.reload!(watch))
  end

  test "changed observations, active leases and tampered confirmation cannot delete an original", %{
    item: item,
    watch: watch
  } do
    {:ok, token} = MediaWatch.release_confirmation(watch)
    {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, token)
    MediaWatch.release_lease(lease)

    observation = %Observation{
      backend: :yt_dlp,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      availability: :public,
      duration_seconds: 120,
      livestream: false
    }

    {:ok, _} = MediaWatch.record_observation(watch, observation)
    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, token)
    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, token <> "tampered")
    assert File.exists?(OriginalArchive.manifest_path(watch.id))
  end

  test "interrupted deletion stays blocked and recovers idempotently", %{item: item, watch: watch} do
    {:ok, token} = MediaWatch.release_confirmation(watch)
    unexpected = Path.join(OriginalArchive.archive_directory(watch.id), "unexpected")
    File.write!(unexpected, "do not erase unknown files")
    assert {:error, {:original_deletion_pending, _}} = MediaWatch.release_watch(item, token)
    assert MediaWatch.watched?(item.id)
    assert MediaWatch.replacement_blocked?(item.id)
    assert {:error, :original_deletion_pending} = MediaWatch.allow_active_file_deletion(item)
    assert File.exists?(OriginalArchive.manifest_path(watch.id))
    assert File.exists?(item.media_filepath)
    File.rm!(unexpected)
    MediaWatch.recover_pending()
    refute File.exists?(OriginalArchive.archive_directory(watch.id))
    refute MediaWatch.watched?(item.id)
    assert Repo.reload!(watch).operation_kind == nil
    assert MediaWatch.recover_pending() == []
  end

  test "active-file deletion cannot overlap a replacement or saved-original release", %{item: item, watch: watch} do
    {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
    assert {:error, :watch_hold} = Pinchflat.Media.delete_media_files(item)
    assert File.read!(item.media_filepath) == "first artifact"
    assert File.exists?(OriginalArchive.manifest_path(watch.id))
    MediaWatch.release_lease(lease)

    {:ok, token} = MediaWatch.release_confirmation(Repo.reload!(watch))

    assert {:ok, _} =
             MediaWatch.with_deletion_fence(item, fn fresh ->
               assert {:error, :stale_confirmation} = MediaWatch.release_watch(fresh, token)
               {:ok, fresh}
             end)

    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, token)
    assert Repo.reload!(watch).released_at == nil
  end

  test "a failed active-file deletion also invalidates older archive consent", %{item: item, watch: watch} do
    {:ok, token} = MediaWatch.release_confirmation(watch)
    File.rm!(item.media_filepath)
    File.mkdir!(item.media_filepath)
    File.write!(Path.join(item.media_filepath, "keep"), "not removable as a media file")
    assert {:error, {:file_delete_failed, _, _}} = Pinchflat.Media.delete_media_files(item)
    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, token)
    assert Repo.reload!(item).media_filepath == item.media_filepath
    assert File.exists?(OriginalArchive.manifest_path(watch.id))
    assert Repo.reload!(watch).released_at == nil
  end

  test "expired confirmation and consent for a different media item are rejected", %{item: item, watch: watch} do
    {:ok, token} = MediaWatch.release_confirmation(watch)
    {:ok, data} = Phoenix.Token.verify(PinchflatWeb.Endpoint, "end-media-watch", token)

    expired =
      Phoenix.Token.sign(PinchflatWeb.Endpoint, "end-media-watch", data, signed_at: System.system_time(:second) - 601)

    assert {:error, :stale_confirmation} = MediaWatch.release_watch(item, expired)
    other = media_item_with_attachments()
    assert {:error, :stale_confirmation} = MediaWatch.release_watch(other, token)
    assert File.exists?(OriginalArchive.manifest_path(watch.id))
  end

  test "recovery refuses a manifest changed after deletion was approved", %{item: item, watch: watch} do
    {:ok, token} = MediaWatch.release_confirmation(watch)
    unexpected = Path.join(OriginalArchive.archive_directory(watch.id), "unexpected")
    File.write!(unexpected, "retain unknown file")
    assert {:error, {:original_deletion_pending, _}} = MediaWatch.release_watch(item, token)
    File.write!(OriginalArchive.manifest_path(watch.id), " ", [:append])
    MediaWatch.recover_pending()
    assert File.exists?(unexpected)
    assert Repo.reload!(watch).operation_kind == "delete_original"
    assert MediaWatch.replacement_blocked?(item.id)
  end

  test "ending a watch with no saved archive keeps the active files", %{item: item, watch: watch} do
    # A first suspicion can arrive before any replacement has needed an archive.
    File.rm_rf!(OriginalArchive.archive_directory(watch.id))
    fresh = watch |> Ecto.Changeset.change(archive_state: "none", original_manifest_path: nil) |> Repo.update!()
    {:ok, token} = MediaWatch.release_confirmation(fresh)
    assert {:ok, _} = MediaWatch.release_watch(item, token)
    assert File.exists?(item.media_filepath)
    assert {:error, :watch_released} = MediaWatch.archive_original(watch, item)
  end

  test "source and profile deletion stay visible until their watches are explicitly released", %{
    conn: conn,
    item: item,
    watch: watch,
    source: source
  } do
    profile = Pinchflat.Profiles.get_media_profile!(source.media_profile_id)
    source_response = delete(conn, ~p"/sources/#{source}")
    assert redirected_to(source_response) == ~p"/sources/#{source}"
    assert Repo.reload!(source).marked_for_deletion_at == nil
    profile_response = delete(recycle(conn), ~p"/media_profiles/#{profile}")
    assert redirected_to(profile_response) == ~p"/media_profiles/#{profile}"
    assert Repo.reload!(profile).marked_for_deletion_at == nil
    assert MediaWatch.deletion_blocked?(source)
    assert MediaWatch.deletion_blocked?(profile)
    {:ok, token} = MediaWatch.release_confirmation(watch)
    {:ok, _} = MediaWatch.release_watch(item, token)
    refute MediaWatch.deletion_blocked?(source)
    refute MediaWatch.deletion_blocked?(profile)
    assert {:ok, _} = Pinchflat.Profiles.delete_media_profile(profile)
  end

  test "filesystem failures reach the browser and API without clearing media paths", %{conn: conn} do
    item = media_item_with_attachments()
    File.rm!(item.media_filepath)
    File.mkdir!(item.media_filepath)
    File.write!(Path.join(item.media_filepath, "keep"), "not a media file")
    browser = delete(conn, ~p"/sources/#{item.source_id}/media/#{item}")
    assert redirected_to(browser) == ~p"/sources/#{item.source_id}/media/#{item}"
    assert Phoenix.Flash.get(browser.assigns.flash, :error) =~ "could not be deleted"
    api = delete(recycle(conn), "/api/media/#{item.id}")
    assert json_response(api, 500)["message"] =~ "could not be deleted"
    assert Repo.reload!(item).media_filepath == item.media_filepath
    assert Repo.reload!(item).culled_at == nil
  end
end
