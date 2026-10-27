defmodule Pinchflat.Downloading.MediaWatchEnrollmentTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch

  setup do
    profile = media_profile_fixture()
    profile |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
    path = Path.join(Application.get_env(:pinchflat, :media_directory), "watch-test-#{item.uuid}.mkv")

    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _opts, _output, _addl ->
        {:ok, "{}"}

      _url, :download_thumbnail, _opts, _output, _addl ->
        {:ok, ""}

      _url, :download, opts, _output, _addl ->
        staged = Path.join(Path.dirname(Keyword.fetch!(opts, :output)), Path.basename(path))
        File.mkdir_p!(Path.dirname(staged))
        File.write!(staged, "first artifact")
        {:ok, metadata(staged)}
    end)

    stub(DiskSpaceCheckerMock, :available_bytes, fn _ -> {:ok, 1_000_000_000_000} end)
    stub(UserScriptRunnerMock, :run, fn _event, _item -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)
    %{item: item, path: path}
  end

  defp metadata(path) do
    :media_metadata
    |> render_metadata()
    |> Jason.decode!()
    |> Map.merge(%{
      "filepath" => path,
      "duration" => 90,
      "availability" => nil,
      "thumbnails" => [],
      "requested_subtitles" => %{},
      "infojson_filename" => nil
    })
    |> Jason.encode!()
  end

  defp run(item, args \\ %{}) do
    MediaDownloadWorker.perform(%Oban.Job{args: Map.merge(%{"id" => item.id}, args)})
  end

  test "first watched download enrolls through configured external staging", %{item: item} do
    root = Path.join(Application.fetch_env!(:pinchflat, :tmpfile_directory), "configured-watch-#{item.uuid}")
    File.mkdir_p!(root)
    prior = Application.get_env(:pinchflat, :download_staging_directory)
    Application.put_env(:pinchflat, :download_staging_directory, root)

    on_exit(fn ->
      Application.put_env(:pinchflat, :download_staging_directory, prior)
      File.rm_rf(root)
    end)

    assert :ok = run(item)
    completed = Repo.reload!(item)
    assert completed.media_downloaded_at
    assert File.read!(completed.media_filepath) == "first artifact"
    assert MediaWatch.get_watch_for_media_item(item.id)
  end

  test "first local completion records one fixed window but not postprocessed duration or nil visibility", %{item: item} do
    assert :ok = run(item)
    completed = Repo.reload!(item)
    assert completed.media_downloaded_at
    assert completed.duration_seconds == 90
    assert completed.watch_postprocessing_pending == false
    assert is_nil(completed.watch_enrollment_pending_at)
    watch = MediaWatch.get_watch_for_media_item(item.id)
    assert watch.media_item_uuid == item.uuid
    assert watch.baseline_visibility == nil
    assert watch.baseline_upstream_duration_seconds == nil
    assert DateTime.diff(watch.ends_at, watch.started_at) == 14 * 86_400
    assert Repo.aggregate(Watch, :count) == 1
    assert :ok = run(item)
    assert Repo.get!(Watch, watch.id).started_at == watch.started_at
  end

  test "SponsorBlock partial metadata does not enroll, then first success enrolls", %{item: item, path: path} do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _, _, _ ->
        {:ok, "{}"}

      _url, :download_thumbnail, _, _, _ ->
        {:ok, ""}

      _url, :download, opts, _, addl ->
        staged = Path.join(Path.dirname(Keyword.fetch!(opts, :output)), Path.basename(path))
        File.mkdir_p!(Path.dirname(staged))

        if Process.get(:watch_partial_attempt) do
          File.write!(staged, "first artifact")
          {:ok, metadata(staged)}
        else
          Process.put(:watch_partial_attempt, true)
          File.write!(staged, "partial")
          File.write!(Keyword.fetch!(addl, :output_filepath), metadata(staged))
          {:error, "Unable to communicate with SponsorBlock", 1}
        end
    end)

    assert {:error, :download_failed} = run(item)
    partial = Repo.reload!(item)
    assert partial.media_filepath == nil
    assert partial.media_downloaded_at == nil
    assert partial.watch_enrollment_pending_at == nil
    assert Repo.aggregate(Watch, :count) == 0
    assert :ok = run(item)
    assert Repo.reload!(item).media_downloaded_at
    assert Repo.aggregate(Watch, :count) == 1
  end

  test "postprocessing error before first success does not enroll", %{item: item} do
    stub(UserScriptRunnerMock, :run, fn
      :media_downloaded, _item ->
        unless Process.get(:watch_script_failed) do
          Process.put(:watch_script_failed, true)
          raise "script failure"
        end

        {:ok, "", 0}

      :media_pre_download, _item ->
        {:ok, "", 0}
    end)

    assert_raise RuntimeError, "script failure", fn -> run(item) end
    partial = Repo.reload!(item)
    assert partial.media_downloaded_at == nil
    assert partial.watch_enrollment_pending_at == nil
    assert Repo.aggregate(Watch, :count) == 0

    # Model a day between transferred bytes and the first successful script.
    earlier = DateTime.add(partial.watch_download_started_at, -86_400, :second)
    partial |> Ecto.Changeset.change(watch_download_started_at: earlier) |> Repo.update!()
    assert :ok = run(item)
    watch = MediaWatch.get_watch_for_media_item(item.id)
    assert DateTime.compare(watch.started_at, earlier) == :gt
    assert DateTime.diff(watch.started_at, earlier, :second) >= 86_400
    assert DateTime.diff(watch.ends_at, watch.started_at, :second) == 14 * 86_400
    assert Repo.aggregate(Watch, :count) == 1
  end

  test "nonzero downloaded-script exit does not enroll until the same artifact is postprocessed", %{
    item: item,
    path: path
  } do
    old_runner = Application.get_env(:pinchflat, :user_script_runner)
    old_extras = Application.get_env(:pinchflat, :extras_directory)
    extras = Path.join(Application.fetch_env!(:pinchflat, :tmpfile_directory), "watch-script-#{item.uuid}")
    script = Path.join([extras, "user-scripts", "lifecycle"])
    File.mkdir_p!(Path.dirname(script))
    File.write!(script, "#!/bin/sh\n[ \"$1\" != media_downloaded ] || exit 1\n")
    File.chmod!(script, 0o700)
    Application.put_env(:pinchflat, :extras_directory, extras)
    Application.put_env(:pinchflat, :user_script_runner, Pinchflat.Lifecycle.UserScripts.CommandRunner)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, old_extras)
      Application.put_env(:pinchflat, :user_script_runner, old_runner)
    end)

    assert {:error, :postprocessing_failed} = run(item)
    pending = Repo.reload!(item)
    assert pending.watch_postprocessing_pending
    assert is_nil(pending.media_downloaded_at)
    assert is_nil(pending.watch_enrollment_pending_at)
    assert is_nil(Pinchflat.Downloading.FirstArtifact.completed_at(pending))
    assert Repo.aggregate(Watch, :count) == 0
    original_hash = :crypto.hash(:sha256, File.read!(path))

    pending
    |> Ecto.Changeset.change(watch_download_started_at: DateTime.add(pending.watch_download_started_at, -86_400))
    |> Repo.update!()

    File.write!(script, "#!/bin/sh\nexit 0\n")
    stub(YtDlpRunnerMock, :run, fn _, :download, _, _, _ -> flunk("script retry must not download") end)
    assert :ok = run(item)
    completed = Repo.reload!(item)
    watch = MediaWatch.get_watch_for_media_item(item.id)
    assert :crypto.hash(:sha256, File.read!(path)) == original_hash
    assert DateTime.diff(watch.started_at, pending.watch_download_started_at) >= 0
    assert DateTime.diff(watch.started_at, DateTime.add(pending.watch_download_started_at, -86_400)) >= 86_400
    assert completed.media_downloaded_at == watch.started_at
    assert DateTime.diff(watch.ends_at, watch.started_at) == 14 * 86_400
  end

  test "two successful workers cannot replace the first immutable completion time", %{item: item, path: path} do
    staged = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "concurrent-#{item.uuid}.mkv")
    File.write!(staged, "first artifact")

    {:ok, started} =
      Pinchflat.Media.update_media_item(item, %{
        watch_download_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    artifact = Pinchflat.Downloading.FirstArtifact
    assert :ok = artifact.remember(started, Jason.decode!(metadata(path)), staged)
    File.rename!(staged, path)
    assert :ok = artifact.mark_transferred(started, Jason.decode!(metadata(path)))

    early = ~U[2026-10-01 00:00:00Z]
    later = DateTime.add(early, 86_400)
    parent = self()

    tasks =
      for time <- [early, later] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> artifact.mark_completed(started, time))
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}
      send(pid, :go)
    end

    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
    first = artifact.completed_at(started)
    assert first in [early, later]
    assert :ok = artifact.mark_completed(started, DateTime.add(later, 86_400))
    assert artifact.completed_at(started) == first
    assert :ok = artifact.mark_transferred(started, Jason.decode!(metadata(path)))
    assert artifact.completed_at(started) == first
  end

  test "first metadata and marker write fault resumes the verified first bytes without yt-dlp", %{
    item: item,
    path: path
  } do
    if Pinchflat.Database.postgres?() do
      Repo.query!("""
      CREATE FUNCTION reject_first_metadata() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'owned first metadata fault'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER reject_first_metadata BEFORE UPDATE OF watch_postprocessing_pending ON media_items
      FOR EACH ROW WHEN (NEW.watch_postprocessing_pending = true AND OLD.watch_postprocessing_pending = false)
      EXECUTE FUNCTION reject_first_metadata()
      """)
    else
      Repo.query!("""
      CREATE TRIGGER reject_first_metadata BEFORE UPDATE OF watch_postprocessing_pending ON media_items
      WHEN NEW.watch_postprocessing_pending = 1 AND OLD.watch_postprocessing_pending = 0
      BEGIN SELECT RAISE(ABORT, 'owned first metadata fault'); END
      """)
    end

    assert {:error, :artifact_persistence_failed} = run(item)
    assert Repo.reload!(item).media_filepath == nil
    assert Repo.reload!(item).watch_postprocessing_pending == false
    first_hash = :crypto.hash(:sha256, File.read!(path))
    assert File.read!(path) == "first artifact"
    assert {:ok, _} = Pinchflat.Downloading.FirstArtifact.recover(Repo.reload!(item))

    stub(YtDlpRunnerMock, :run, fn
      _, :download, _, _, _ -> flunk("retry must not download")
      _, :download_thumbnail, _, _, _ -> {:ok, ""}
    end)

    assert {:error, :first_artifact_needs_recovery} = run(item)
    assert File.read!(path) == "first artifact"

    Repo.query!(
      "DROP TRIGGER reject_first_metadata" <> if(Pinchflat.Database.postgres?(), do: " ON media_items", else: "")
    )

    assert :ok = run(item)
    completed = Repo.reload!(item)
    watch = MediaWatch.get_watch_for_media_item(item.id)
    assert completed.media_filepath == path
    assert :crypto.hash(:sha256, File.read!(path)) == first_hash
    assert completed.media_downloaded_at == watch.started_at
    assert DateTime.diff(watch.ends_at, watch.started_at) == 14 * 86_400
  end

  test "interrupted transfer intent holds the artifact without redownloading or claiming completion", %{
    item: item,
    path: path
  } do
    staged = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "prepared-#{item.uuid}.mkv")
    File.write!(staged, "first artifact")

    {:ok, started} =
      Pinchflat.Media.update_media_item(item, %{
        watch_download_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :ok = Pinchflat.Downloading.FirstArtifact.remember(started, Jason.decode!(metadata(path)), staged)
    assert Pinchflat.Downloading.FirstArtifact.pending?(started)

    stub(YtDlpRunnerMock, :run, fn
      _, :download, _, _, _ -> flunk("uncertain transfer must not start another download")
    end)

    assert {:error, :first_artifact_needs_recovery} = run(item)
    assert {:error, :first_artifact_needs_recovery} = run(item)
    refute File.exists?(path)
    assert File.read!(staged) == "first artifact"
    assert Repo.reload!(item).media_downloaded_at == nil
    assert Repo.aggregate(Watch, :count) == 0
  end

  test "failed enrollment retains the first artifact and retries without yt-dlp", %{item: item, path: path} do
    stub(UserScriptRunnerMock, :run, fn
      :media_downloaded, _ ->
        unless Process.get(:watch_script_failed) do
          Process.put(:watch_script_failed, true)
          raise "script failure"
        end

        {:ok, "", 0}

      :media_pre_download, _ ->
        {:ok, "", 0}
    end)

    assert_raise RuntimeError, "script failure", fn -> run(item) end
    assert Repo.reload!(item).watch_postprocessing_pending
    assert is_nil(Repo.reload!(item).watch_enrollment_pending_at)

    if Pinchflat.Database.postgres?() do
      Repo.query!("""
      CREATE FUNCTION reject_watch_insert() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'owned watch failure'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER watch_insert_failure BEFORE INSERT ON media_watches
      FOR EACH ROW EXECUTE FUNCTION reject_watch_insert()
      """)
    else
      Repo.query!(
        "CREATE TRIGGER watch_insert_failure BEFORE INSERT ON media_watches BEGIN SELECT RAISE(ABORT, 'owned watch failure'); END"
      )
    end

    assert {:error, :enrollment_failed} = run(item)

    assert Repo.reload!(item).media_downloaded_at == nil
    pending = Repo.reload!(item)
    assert pending.watch_enrollment_pending_at
    assert File.read!(path) == "first artifact"
    assert Repo.aggregate(Watch, :count) == 0

    # Model a later enrollment retry; the saved successful script date wins.
    fixed_success = DateTime.add(pending.watch_enrollment_pending_at, -86_400, :second)
    pending |> Ecto.Changeset.change(watch_enrollment_pending_at: fixed_success) |> Repo.update!()

    Repo.query!(
      "DROP TRIGGER watch_insert_failure" <> if(Pinchflat.Database.postgres?(), do: " ON media_watches", else: "")
    )

    expect(YtDlpRunnerMock, :run, 0, fn _, :download, _, _, _ -> flunk("retry must not download") end)
    assert :ok = run(item)
    assert Repo.reload!(item).media_downloaded_at == fixed_success
    assert File.read!(path) == "first artifact"
    assert MediaWatch.get_watch_for_media_item(item.id).started_at == fixed_success
    assert DateTime.diff(MediaWatch.get_watch_for_media_item(item.id).ends_at, fixed_success) == 14 * 86_400
    assert Repo.aggregate(Watch, :count) == 1
  end

  test "a failed postprocessing marker write retries the same artifact with its first timestamp", %{
    item: item,
    path: path
  } do
    stub(UserScriptRunnerMock, :run, fn
      :media_downloaded, _ ->
        unless Process.get(:watch_finalization_failed) do
          Process.put(:watch_finalization_failed, true)
          raise "postprocessing failed"
        end

        {:ok, "", 0}

      :media_pre_download, _ ->
        {:ok, "", 0}
    end)

    assert_raise RuntimeError, "postprocessing failed", fn -> run(item) end
    pending = Repo.reload!(item)
    assert pending.watch_postprocessing_pending
    assert is_nil(pending.watch_enrollment_pending_at)
    assert File.read!(path) == "first artifact"
    transferred_at = DateTime.add(pending.watch_download_started_at, -86_400, :second)
    pending |> Ecto.Changeset.change(watch_download_started_at: transferred_at) |> Repo.update!()

    if Pinchflat.Database.postgres?() do
      Repo.query!("""
      CREATE FUNCTION reject_watch_finalization() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'owned finalization failure'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER reject_watch_finalization BEFORE UPDATE OF watch_postprocessing_pending ON media_items
      FOR EACH ROW WHEN (NEW.watch_postprocessing_pending = false AND OLD.watch_postprocessing_pending = true)
      EXECUTE FUNCTION reject_watch_finalization()
      """)
    else
      Repo.query!("""
      CREATE TRIGGER reject_watch_finalization BEFORE UPDATE OF watch_postprocessing_pending ON media_items
      WHEN NEW.watch_postprocessing_pending = 0 AND OLD.watch_postprocessing_pending = 1
      BEGIN SELECT RAISE(ABORT, 'owned finalization failure'); END
      """)
    end

    assert {:error, :finalization_failed} = run(item)
    first_success = Pinchflat.Downloading.FirstArtifact.completed_at(pending)
    assert first_success
    assert DateTime.compare(first_success, transferred_at) == :gt

    Repo.query!(
      "DROP TRIGGER reject_watch_finalization" <> if(Pinchflat.Database.postgres?(), do: " ON media_items", else: "")
    )

    expect(YtDlpRunnerMock, :run, 0, fn _, :download, _, _, _ -> flunk("retry must not download") end)
    assert :ok = run(item)
    assert Repo.reload!(item).media_downloaded_at == first_success
    assert MediaWatch.get_watch_for_media_item(item.id).started_at == first_success
    assert DateTime.diff(MediaWatch.get_watch_for_media_item(item.id).ends_at, first_success) == 14 * 86_400
    assert File.read!(path) == "first artifact"
  end

  test "a legacy NULL completion with an existing file is never prospectively enrolled", %{item: item, path: path} do
    File.write!(path, "legacy artifact")
    {:ok, item} = Pinchflat.Media.update_media_item(item, %{media_filepath: path})
    stub(DiskSpaceCheckerMock, :available_bytes, fn _ -> {:ok, 1_000_000_000_000} end)

    stub(YtDlpRunnerMock, :run, fn
      _url, :download, options, _output, _addl ->
        staged = Path.join(Path.dirname(Keyword.fetch!(options, :output)), "legacy-retry.mkv")
        File.mkdir_p!(Path.dirname(staged))
        File.write!(staged, "new artifact")

        {:ok,
         metadata(staged)
         |> Jason.decode!()
         |> Map.merge(%{"thumbnails" => [], "requested_subtitles" => %{}, "infojson_filename" => nil})
         |> Jason.encode!()}

      _url, :get_downloadable_status, _opts, _output, _addl ->
        {:ok, "{}"}

      _url, :download_thumbnail, _opts, _output, _addl ->
        {:ok, ""}
    end)

    assert :ok = run(item, %{"force" => true})
    assert Repo.aggregate(Watch, :count) == 0
    assert Repo.reload!(item).watch_download_started_at == nil
  end

  test "old-library force failure with an intact file never enrolls", %{item: item, path: path} do
    old = ~U[2024-01-01 00:00:00Z]
    File.write!(path, "old library")
    {:ok, item} = Pinchflat.Media.update_media_item(item, %{media_filepath: path, media_downloaded_at: old})
    stub(DiskSpaceCheckerMock, :available_bytes, fn _ -> {:ok, 1_000_000_000_000} end)

    stub(YtDlpRunnerMock, :run, fn
      _url, :download, _, _, _ -> {:error, "Unable to communicate with SponsorBlock", 1}
      _url, :get_downloadable_status, _, _, _ -> {:ok, "{}"}
    end)

    assert {:error, :download_failed} = run(item, %{"force" => true})
    assert Repo.reload!(item).media_downloaded_at == old
    assert File.read!(path) == "old library"
    assert Repo.aggregate(Watch, :count) == 0
  end

  test "old-library force finalization error never erases its original completion or enrolls", %{item: item, path: path} do
    old = ~U[2024-01-01 00:00:00Z]
    File.write!(path, "old library")
    {:ok, item} = Pinchflat.Media.update_media_item(item, %{media_filepath: path, media_downloaded_at: old})

    # A missing old file does not permit a force retry to claim first success.
    File.rm!(path)

    stub(UserScriptRunnerMock, :run, fn
      :media_pre_download, _item -> {:ok, "", 0}
      :media_downloaded, _item -> raise "script failure"
    end)

    assert_raise RuntimeError, "script failure", fn -> run(item, %{"force" => true}) end
    assert Repo.reload!(item).media_downloaded_at == old
    assert Repo.reload!(item).watch_download_started_at == nil
    assert Repo.aggregate(Watch, :count) == 0
  end
end
