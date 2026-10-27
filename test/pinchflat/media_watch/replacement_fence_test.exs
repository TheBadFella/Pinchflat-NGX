defmodule Pinchflat.MediaWatch.ReplacementFenceTest do
  @moduledoc """
  Covers the M2 central replacement fence.

  The journal, gate and refusal cases run by default and never move a watched
  active original. The replacement, crash and recovery cases actually overwrite
  or restore active files, so they are tagged `:destructive_watch` and only run
  after the independent M2 safety review approves explicit execution:

      mix test --include destructive_watch test/pinchflat/media_watch/replacement_fence_test.exs
  """

  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Downloading.MediaDownloader
  alias Pinchflat.Media
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.MediaWatch.ReplacementIntent
  alias Pinchflat.Repo

  setup context do
    stub(DiskSpaceCheckerMock, :available_bytes, fn _ -> {:ok, 100 * 1024 * 1024 * 1024} end)

    unless Map.get(context, :destructive_watch, false) do
      Application.delete_env(:pinchflat, :media_watch_destructive_enabled)
    end

    if Map.get(context, :destructive_watch, false) do
      Application.put_env(:pinchflat, :media_watch_destructive_enabled, true)
    end

    on_exit(fn ->
      Application.delete_env(:pinchflat, :media_watch_destructive_enabled)
      File.rm_rf(OriginalArchive.root())
      File.rm_rf(DownloadStaging.replacement_directory())
    end)

    :ok
  end

  describe "replacement intent journal" do
    test "publishes exclusively, advances in place and clears only its own operation" do
      watch_id = 987_654
      File.mkdir_p!(OriginalArchive.archive_directory(watch_id))
      operation_id = Ecto.UUID.generate()

      assert {:ok, intent} =
               ReplacementIntent.publish(watch_id, %{
                 "operation_id" => operation_id,
                 "phase" => "prepared",
                 "active" => [],
                 "staged" => []
               })

      assert intent["watch_id"] == watch_id
      assert ReplacementIntent.pending?(watch_id)
      assert watch_id in ReplacementIntent.pending_watch_ids()

      assert {:error, :replacement_already_in_progress} =
               ReplacementIntent.publish(watch_id, %{
                 "operation_id" => Ecto.UUID.generate(),
                 "phase" => "prepared",
                 "active" => [],
                 "staged" => []
               })

      assert :ok = ReplacementIntent.advance(intent, "transferring")

      assert {:ok, %{"phase" => "transferring", "operation_id" => ^operation_id}} =
               ReplacementIntent.read(watch_id)

      assert {:error, :operation_mismatch} = ReplacementIntent.clear(watch_id, Ecto.UUID.generate())
      assert ReplacementIntent.pending?(watch_id)

      assert :ok = ReplacementIntent.clear(watch_id, operation_id)
      refute ReplacementIntent.pending?(watch_id)
      assert {:error, :not_pending} = ReplacementIntent.read(watch_id)
    end
  end

  describe "unapproved fence" do
    test "a disabled execution gate refuses the commit before any file moves" do
      Application.put_env(:pinchflat, :media_watch_destructive_enabled, false)
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :watch_guard_unapproved} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images -> flunk("transfer must not run while the gate is disabled") end,
                 fn _json -> flunk("database update must not run while the gate is disabled") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      refute ReplacementIntent.pending?(watch.id)
      assert MediaWatch.lease_current?(lease)
    end

    test "recovery clears a journal whose operation the database already committed" do
      {item, watch} = watched_item()
      operation_id = Ecto.UUID.generate()
      commit_watch(watch, operation_id)

      {:ok, manifest} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))

      assert {:ok, _intent} =
               ReplacementIntent.publish(watch.id, %{
                 "operation_id" => operation_id,
                 "phase" => "transferring",
                 "active" => active_entries(item, watch, manifest),
                 "staged" => []
               })

      assert [%{watch_id: watch_id, action: :commit_confirmed}] =
               Enum.filter(MediaWatch.recover_pending(), &(&1.watch_id == watch.id))

      assert watch_id == watch.id
      refute ReplacementIntent.pending?(watch.id)
      assert File.read!(item.media_filepath) == "first artifact"
    end
  end

  describe "approved fenced replacement" do
    @describetag :destructive_watch

    test "a fenced commit replaces the active file only after its archive is published" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:ok, updated} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images ->
                   File.rename!(staged, item.media_filepath)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> Media.update_media_item(item, %{title: "replacement title"}) end
               )

      assert updated.title == "replacement title"
      assert File.read!(item.media_filepath) == "replacement artifact"

      committed = Repo.get!(Watch, watch.id)
      assert is_binary(committed.operation_id)
      assert is_nil(committed.lease_owner)
      assert is_nil(committed.lease_expires_at)
      refute ReplacementIntent.pending?(watch.id)

      assert {:ok, manifest} = MediaWatch.verify_archive(committed)
      first_checksum = :sha256 |> :crypto.hash("first artifact") |> Base.encode16(case: :lower)

      assert [%{"role" => "media", "sha256" => ^first_checksum}] =
               Enum.filter(manifest["files"], &(&1["role"] == "media"))
    end

    test "a corrupt second-replacement backup cannot displace the intact approved active file" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:ok, _} = MediaWatch.commit_replacement(
               lease,
               item,
               %{source_map: %{staged => item.media_filepath}},
               fn _ ->
                 File.rename!(staged, item.media_filepath)
                 {:ok, %{"filepath" => item.media_filepath}}
               end,
               fn _ -> Media.update_media_item(item, %{title: "replacement"}) end
             )

      operation = Ecto.UUID.generate()
      backup = ReplacementIntent.backup_path(item.media_filepath, operation)
      File.write!(backup, "damaged pre-image!!")
      approved = File.read!(item.media_filepath)
      hash = Base.encode16(:crypto.hash(:sha256, approved), case: :lower)
      intent = %{
        "watch_id" => watch.id,
        "operation_id" => operation,
        "active" => [%{"role" => "media", "path" => item.media_filepath, "backup" => backup, "sha256" => hash}],
        "staged" => []
      }

      assert :ok = ReplacementIntent.restore(intent)
      assert File.read!(item.media_filepath) == approved
      assert File.read!(backup) == "damaged pre-image!!"

      File.write!(item.media_filepath, "unapproved changes")
      assert {:error, {"media", :pre_image_unavailable}} = ReplacementIntent.restore(intent)
      assert File.read!(item.media_filepath) == "unapproved changes"
      assert File.read!(backup) == "damaged pre-image!!"
    end

    test "missing backup recovery preserves newer active bytes beside the restored original" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :transfer_failed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   refute File.exists?(pre_images[item.media_filepath])
                   File.write!(item.media_filepath, "recoverable newer bytes")
                   {:error, :transfer_failed}
                 end,
                 fn _ -> flunk("failed transfers must not update the item") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
      assert {:ok, directories} = File.ls(quarantine_root())
      assert [directory] = Enum.filter(directories, &String.starts_with?(&1, "quarantine-"))
      assert {:ok, files} = File.ls(Path.join(quarantine_root(), directory))
      assert Enum.map(files, &File.read!(Path.join([quarantine_root(), directory, &1]))) == ["recoverable newer bytes"]
    end

    test "a quarantine collision retains the newer file and the recovery journal" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")
      parent = self()

      assert {:error, {:replacement_recovery_failed, :transfer_failed, {"media", :quarantine_destination_exists}}} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   refute File.exists?(pre_images[item.media_filepath])
                   {:ok, intent} = ReplacementIntent.read(watch.id)
                   assert {:ok, [saved]} =
                            ReplacementIntent.quarantine(watch.id, intent["operation_id"], [item.media_filepath])

                   send(parent, {:saved_file, saved})
                   File.write!(item.media_filepath, "recoverable newer bytes")
                   {:error, :transfer_failed}
                 end,
                 fn _ -> flunk("failed transfers must not update the item") end
               )

      assert_received {:saved_file, saved}
      assert File.read!(saved) == "first artifact"
      assert File.read!(item.media_filepath) == "recoverable newer bytes"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      assert ReplacementIntent.pending?(watch.id)
    end

    test "a second replacement accepts only the last approved bytes, not a later manual edit" do
      {item, watch} = watched_item()
      original = watch.approved_active_files["first"]

      for {content, title} <- [{"second artifact", "second"}, {"third artifact", "third"}] do
        {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
        staged = staged_file(content)

        assert {:ok, _} =
                 MediaWatch.commit_replacement(
                   lease,
                   item,
                   %{source_map: %{staged => item.media_filepath}},
                   fn _ ->
                     File.rename!(staged, item.media_filepath)
                     {:ok, %{"filepath" => item.media_filepath}}
                   end,
                   fn _ -> Media.update_media_item(item, %{title: title}) end
                 )

        assert File.read!(item.media_filepath) == content
        assert Repo.get!(Watch, watch.id).approved_active_files["first"] == original
        assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      end

      File.write!(item.media_filepath, "user edit")
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("fourth artifact")

      assert {:error, :active_file_changed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _ -> flunk("manual edits cannot be replaced") end,
                 fn _ -> flunk("manual edits cannot be approved") end
               )

      assert File.read!(item.media_filepath) == "user edit"
    end

    test "an unverifiable older replacement refuses adoption" do
      {item, watch} = watched_item()
      watch |> Ecto.Changeset.change(approved_active_files: nil) |> Repo.update!()
      commit_watch(watch, Ecto.UUID.generate())
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :active_file_unverifiable} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _ -> flunk("unverifiable current files cannot be replaced") end,
                 fn _ -> flunk("unverifiable current files cannot be approved") end
               )
    end

    test "an expired lease refuses the commit and never moves the active file" do
      {item, _watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace", lease_seconds: -1)
      staged = staged_file("replacement artifact")

      assert {:error, :lost_lease} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images -> flunk("a lost lease must not transfer files") end,
                 fn _json -> flunk("a lost lease must not update the database") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      assert File.regular?(staged)
    end

    test "an observation version change under the lease refuses the commit" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      Repo.update_all(from(w in Watch, where: w.id == ^watch.id), inc: [observation_version: 1])

      assert {:error, :watch_hold} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images -> flunk("a changed observation must not transfer files") end,
                 fn _json -> flunk("a changed observation must not update the database") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a manual edit after publication is refused without touching any file" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      File.write!(item.media_filepath, "edited by hand")

      assert {:error, :active_file_changed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images -> flunk("a changed active file must not be overwritten") end,
                 fn _json -> flunk("a changed active file must not be recorded") end
               )

      assert File.read!(item.media_filepath) == "edited by hand"
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a pre-transfer failure restores the exact archived bytes" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :simulated_crash} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images -> {:error, :simulated_crash} end,
                 fn _json -> flunk("a failed transfer must not update the database") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      assert {:ok, _manifest} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
      assert Repo.get!(Watch, watch.id).archive_state == "published"
    end

    test "a mid-transfer crash restores every archived active file" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")
      original_hashes = hashes_for(item)

      assert {:error, :simulated_mid_move_crash} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images ->
                   File.write!(item.media_filepath, "half a replacement")
                   {:error, :simulated_mid_move_crash}
                 end,
                 fn _json -> flunk("a partial transfer must not update the database") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      assert hashes_for(item) == original_hashes
      refute ReplacementIntent.pending?(watch.id)
      assert Repo.get!(Watch, watch.id).archive_state == "published"
    end

    test "a database failure after the move restores the original and rolls back" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")
      original_hashes = hashes_for(item)

      assert {:error, {:update_raised, "database unavailable"}} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images ->
                   File.rename!(staged, item.media_filepath)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> raise "database unavailable" end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      assert hashes_for(item) == original_hashes
      assert Media.get_media_item!(item.id).title == item.title
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a lease superseded during the transfer restores the original" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :lost_lease} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images ->
                   File.rename!(staged, item.media_filepath)

                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
                     set: [lease_expires_at: now_minus(1, :minute)]
                   )

                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("a superseded lease must not update the database") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a new sidecar written by a failed transfer is quarantined, not left active" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")
      new_sidecar = Path.join(Path.dirname(item.media_filepath), "new-sidecar.info.json")

      assert {:error, :simulated_sidecar_failure} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath, staged_sidecar(new_sidecar) => new_sidecar}},
                 fn _pre_images ->
                   File.write!(new_sidecar, "new sidecar")
                   {:error, :simulated_sidecar_failure}
                 end,
                 fn _json -> flunk("a partial transfer must not update the database") end
               )

      refute File.exists?(new_sidecar)
      assert File.read!(item.media_filepath) == "first artifact"
      assert File.ls!(quarantine_root()) != []
      refute ReplacementIntent.pending?(watch.id)
    end

    test "failed replacement quarantines both new files with the same basename" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      en = Path.join([Path.dirname(item.media_filepath), "en", "video.vtt"])
      es = Path.join([Path.dirname(item.media_filepath), "es", "video.vtt"])
      staged = %{staged_sidecar(en) => en, staged_sidecar(es) => es}

      assert {:error, :simulated_sidecar_failure} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: staged},
                 fn _ ->
                   File.mkdir_p!(Path.dirname(en))
                   File.mkdir_p!(Path.dirname(es))
                   File.write!(en, "English subtitle")
                   File.write!(es, "Spanish subtitle")
                   {:error, :simulated_sidecar_failure}
                 end,
                 fn _ -> flunk("a partial transfer must not update metadata") end
               )

      refute File.exists?(en)
      refute File.exists?(es)
      assert File.read!(item.media_filepath) == "first artifact"
      refute ReplacementIntent.pending?(watch.id)

      [directory] = Enum.filter(File.ls!(quarantine_root()), &String.starts_with?(&1, "quarantine-#{watch.id}-"))
      recovered =
        quarantine_root()
        |> Path.join(directory)
        |> File.ls!()
        |> Enum.map(&File.read!(Path.join([quarantine_root(), directory, &1])))

      assert Enum.sort(recovered) == ["English subtitle", "Spanish subtitle"]
    end

    test "recovery keeps replacement bytes when the database already committed the operation" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:ok, _updated} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images ->
                   File.rename!(staged, item.media_filepath)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> Media.update_media_item(item, %{title: "replacement title"}) end
               )

      committed = Repo.get!(Watch, watch.id)
      {:ok, manifest} = MediaWatch.verify_archive(committed)

      assert {:ok, _intent} =
               ReplacementIntent.publish(watch.id, %{
                 "operation_id" => committed.operation_id,
                 "phase" => "transferring",
                 "active" => active_entries(item, watch, manifest),
                 "staged" => []
               })

      assert [%{action: :commit_confirmed}] =
               Enum.filter(MediaWatch.recover_pending(), &(&1.watch_id == watch.id))

      assert File.read!(item.media_filepath) == "replacement artifact"
      refute ReplacementIntent.pending?(watch.id)
    end

    test "the downloader commits a watched replacement through the fence" do
      {item, watch} = watched_item()
      media_root = Application.fetch_env!(:pinchflat, :media_directory) |> Path.expand()
      relative_directory = Path.relative_to(Path.dirname(item.media_filepath), media_root)

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _output, _addl ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _output, _addl ->
          {:ok, ""}

        _url, :download, opts, _output, _addl ->
          staged = Path.join([Path.dirname(Keyword.fetch!(opts, :output)), relative_directory, "media.mp4"])
          File.mkdir_p!(Path.dirname(staged))
          File.write!(staged, "replacement artifact")
          {:ok, downloader_metadata(staged)}
      end)

      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

      assert {:ok, updated} = MediaDownloader.download_for_media_item(item)
      assert updated.media_filepath == item.media_filepath
      assert File.read!(item.media_filepath) == "replacement artifact"

      committed = Repo.get!(Watch, watch.id)
      assert is_binary(committed.operation_id)
      assert is_nil(committed.lease_owner)
      refute ReplacementIntent.pending?(watch.id)

      assert {:ok, manifest} = MediaWatch.verify_archive(committed)
      first_checksum = :sha256 |> :crypto.hash("first artifact") |> Base.encode16(case: :lower)

      assert [%{"role" => "media", "sha256" => ^first_checksum}] =
               Enum.filter(manifest["files"], &(&1["role"] == "media"))
    end
  end

  defp watched_item do
    profile =
      media_profile_fixture()
      |> Ecto.Changeset.change(watch_window_days: 14)
      |> Repo.update!()

    source = source_fixture(%{media_profile_id: profile.id})

    item =
      media_item_with_attachments(%{source_id: source.id, metadata_filepath: nil, nfo_filepath: nil})

    File.write!(item.media_filepath, "first artifact")

    {:ok, watch} = Pinchflat.MediaWatchFixtures.enroll_approved_watch(item, Repo.preload(source, :media_profile))
    {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(1, :day)})

    item = Repo.preload(Repo.reload(item), [:metadata, source: :media_profile])
    {:ok, published} = MediaWatch.archive_original(watch, item)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, watch} =
      published
      |> Ecto.Changeset.change(last_success_at: now, next_check_at: now)
      |> Repo.update()

    {Repo.reload(item), watch}
  end

  defp downloader_metadata(path) do
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

  defp commit_watch(watch, operation_id) do
    watch
    |> Ecto.Changeset.change(operation_id: operation_id, lease_owner: nil, lease_expires_at: nil)
    |> Repo.update!()
  end

  defp active_entries(item, _watch, manifest) do
    {:ok, %{entries: entries}} = OriginalArchive.archive_entries(item)

    by_role = Map.new(manifest["files"], fn file -> {file["role"], file} end)

    Enum.map(entries, fn entry ->
      %{
        "role" => entry.role,
        "path" => Path.expand(entry.source),
        "sha256" => by_role[entry.role]["sha256"],
        "size" => by_role[entry.role]["size"]
      }
    end)
  end

  defp staged_file(contents) do
    directory = Path.join(DownloadStaging.replacement_directory(), "staged-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    path = Path.join(directory, "media.mp4")
    File.write!(path, contents)
    path
  end

  defp staged_sidecar(destination) do
    directory = Path.join(DownloadStaging.replacement_directory(), "staged-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    path = Path.join(directory, Path.basename(destination))
    File.write!(path, "new sidecar")
    path
  end

  defp hashes_for(item) do
    subtitle_paths = Enum.map(item.subtitle_filepaths, fn [_language, path] -> path end)

    [item.media_filepath, item.thumbnail_filepath | subtitle_paths]
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn path -> {path, :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)} end)
  end

  defp quarantine_root do
    Path.join(Application.fetch_env!(:pinchflat, :media_directory), ".pinchflat-replacements")
  end
end
