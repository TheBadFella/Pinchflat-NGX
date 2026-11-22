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

  import Phoenix.ConnTest
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.MediaWatch.ReplacementIntent
  alias Pinchflat.Repo

  @endpoint PinchflatWeb.Endpoint

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

      assert {:ok, _} =
               MediaWatch.commit_replacement(
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
      assert no_restore_copies?(item.media_filepath)
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
      assert no_restore_copies?(item.media_filepath)

      Repo.update_all(from(w in Watch, where: w.id == ^watch.id), set: [lease_expires_at: now_minus(1, :minute)])

      for _ <- 1..2 do
        assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id and &1.action == :needs_recovery))
        assert File.read!(saved) == "first artifact"
        assert File.read!(item.media_filepath) == "recoverable newer bytes"
        assert ReplacementIntent.pending?(watch.id)
        assert no_restore_copies?(item.media_filepath)
      end
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

    test "a replacement finishing after lease expiry keeps its database reservation" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.prepare_replacement(item)
      staged = staged_file("replacement artifact")

      assert {:ok, updated} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _ ->
                   File.rename!(staged, item.media_filepath)

                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
                     set: [lease_expires_at: now_minus(1, :minute)]
                   )

                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _ -> Media.update_media_item(item, %{title: "replacement title"}) end
               )

      assert Repo.reload!(item).title == updated.title
      assert File.read!(updated.media_filepath) == "replacement artifact"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
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

      assert {:error, :watch_hold} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _pre_images ->
                   File.rename!(staged, item.media_filepath)

                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
                     inc: [lease_generation: 1]
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

    test "an API-queued watched replacement commits through the fence" do
      {item, watch} = watched_item()
      mock_replacement_download(item)
      job = enqueue_force_download(item)

      assert :ok = MediaDownloadWorker.perform(job)
      updated = Repo.reload!(item)
      assert updated.media_filepath == item.media_filepath
      assert is_nil(updated.last_error)
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

    test "an API-queued replacement held by the file guard records the error and stops retrying" do
      {item, watch} = watched_item()
      File.write!(item.media_filepath, "user edit")
      mock_replacement_download(item)
      job = enqueue_force_download(item)

      assert {:ok, :non_retry} = MediaDownloadWorker.perform(job)
      failed = Repo.reload!(item)
      assert failed.error_type == :transient
      assert failed.last_error == "watched original is protected: :active_file_changed"
      assert File.read!(item.media_filepath) == "user edit"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
      assert File.ls!(DownloadStaging.replacement_directory()) == []
    end
  end

  describe "restoring a missing active original" do
    @describetag :destructive_watch

    test "restores deleted active media from the verified published archive" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      File.rm!(item.media_filepath)

      assert {:ok, restored} = MediaWatch.restore_active_from_archive(item)

      assert restored.id == item.id
      assert File.read!(item.media_filepath) == original
      assert {:ok, %{sha256: _expected}} = ReplacementIntent.fingerprint(item.media_filepath)
      assert Repo.get!(Watch, watch.id).lease_owner == nil
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
    end

    test "a present but damaged active file is never overwritten by restoration" do
      {item, _watch} = watched_item()
      File.write!(item.media_filepath, "corrupted replacement")

      # Missing-only recovery: a file on disk is the operator's, so restoration
      # reports success without touching it and nothing is published over it.
      assert {:ok, _restored} = MediaWatch.restore_active_from_archive(item)

      assert File.read!(item.media_filepath) == "corrupted replacement"
      assert no_restore_copies?(item.media_filepath)
    end

    test "refuses to restore when no original was ever published" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)
      watch |> Ecto.Changeset.change(archive_state: "needs_recovery") |> Repo.update!()

      assert {:error, :watch_archive_required} = MediaWatch.restore_active_from_archive(item)
      refute File.exists?(item.media_filepath)
    end
  end

  describe "durable missing-file restoration" do
    @describetag :destructive_watch

    test "a file appearing during the copy is preserved and never overwritten" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      assert {:ok, _} =
               MediaWatch.restore_active_from_archive(item,
                 before_publish: fn -> File.write!(item.media_filepath, "operator wrote this") end
               )

      assert File.read!(item.media_filepath) == "operator wrote this"
      refute ReplacementIntent.restore_pending?(watch.id)
      assert no_restore_copies?(item.media_filepath)
    end

    test "a present edited sidecar is preserved by missing-only restoration" do
      {item, watch} = watched_item()
      File.write!(item.thumbnail_filepath, "operator thumbnail")
      File.rm!(item.media_filepath)

      assert {:ok, _} = MediaWatch.restore_active_from_archive(item)

      assert File.read!(item.thumbnail_filepath) == "operator thumbnail"
      assert File.read!(item.media_filepath) == "first artifact"
      refute ReplacementIntent.restore_pending?(watch.id)
    end
  end

  describe "durable restore reconciliation" do
    @describetag :destructive_watch

    test "a partial restoration is reconciled from the durable journal on restart" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      archive_file = watched_archive_media(watch)
      File.cp!(archive_file, temporary)

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => sha256_of(temporary),
                     "size" => File.stat!(temporary).size
                   }
                 ]
               })

      refute File.exists?(item.media_filepath)
      assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id and &1.action == :restore_reconciled))

      assert File.read!(item.media_filepath) == "first artifact"
      refute File.exists?(temporary)
      refute ReplacementIntent.restore_pending?(watch.id)
    end

    test "a restore superseded before publication is rejected and leaves no active file" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      assert {:error, :watch_hold} =
               MediaWatch.restore_active_from_archive(item,
                 before_publish: fn ->
                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id), inc: [lease_generation: 1])
                 end
               )

      refute File.exists?(item.media_filepath)
      # The journal and its verified temporary are retained for reconciliation
      # rather than silently discarded, and nothing reached the active path.
      assert ReplacementIntent.restore_pending?(watch.id)
      refute no_restore_copies?(item.media_filepath)
    end

    test "a restore database commit failure after publication retains the journal and retry reconciles" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      archive_file = watched_archive_media(watch)
      File.cp!(archive_file, temporary)
      before_commit = Repo.get!(Watch, watch.id).approved_active_files

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => sha256_of(temporary),
                     "size" => File.stat!(temporary).size
                   }
                 ]
               })

      assert [%{watch_id: watch_id, action: :needs_recovery}] =
               Enum.filter(
                 MediaWatch.recover_pending(
                   before_restore_commit: fn _watch_id -> Repo.rollback(:simulated_db_error) end
                 ),
                 &(&1.watch_id == watch.id)
               )

      assert watch_id == watch.id
      # The bytes were published before the database commit failed, so the file
      # is active even though the approvals never landed.
      assert File.read!(item.media_filepath) == original
      assert ReplacementIntent.restore_pending?(watch.id)
      assert Repo.get!(Watch, watch.id).approved_active_files == before_commit

      assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id and &1.action == :restore_reconciled))

      assert File.read!(item.media_filepath) == original
      refute ReplacementIntent.restore_pending?(watch.id)

      media_path = Path.expand(item.media_filepath)

      assert Enum.any?(Repo.get!(Watch, watch.id).approved_active_files, fn {_key, file} ->
               file["path"] == media_path and file["sha256"] == sha256_of(item.media_filepath)
             end)
    end
  end

  describe "restore recovery integrity" do
    @describetag :destructive_watch

    test "an unverified truncated temporary is never published and its journal is kept" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      File.write!(temporary, "truncated")

      archive_file = watched_archive_media(watch)
      full_size = File.stat!(archive_file).size

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => sha256_of(archive_file),
                     "size" => full_size
                   }
                 ]
               })

      assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id))

      refute File.exists?(item.media_filepath),
             "truncated bytes must never be published as the active original"

      assert File.read!(temporary) == "truncated"
      assert ReplacementIntent.restore_pending?(watch.id)
    end

    test "a live restore owner is never raced by recovery" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      # A live worker holds the lease into the future while it copies.
      {:ok, lease} = MediaWatch.claim_lease(item.id, "restore_active", lease_seconds: 300)
      operation_id = lease.owner
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      archive_file = watched_archive_media(watch)
      File.cp!(archive_file, temporary)

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => sha256_of(archive_file),
                     "size" => File.stat!(archive_file).size
                   }
                 ]
               })

      # Recovery reports the live owner and touches nothing it owns.
      assert Enum.any?(
               MediaWatch.recover_pending(),
               &(&1.watch_id == watch.id and &1.action == :restore_in_progress)
             )

      refute File.exists?(item.media_filepath)
      assert File.regular?(temporary)
      assert ReplacementIntent.restore_pending?(watch.id)
      assert MediaWatch.lease_current?(lease)
    end

    test "recovery publishes a verified temporary and refreshes the approved files" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      archive_file = watched_archive_media(watch)
      File.cp!(archive_file, temporary)
      digest = sha256_of(archive_file)

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => digest,
                     "size" => File.stat!(archive_file).size
                   }
                 ]
               })

      assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id and &1.action == :restore_reconciled))

      assert File.read!(item.media_filepath) == "first artifact"
      refute File.exists?(temporary)
      refute ReplacementIntent.restore_pending?(watch.id)

      approved = Repo.get!(Watch, watch.id).approved_active_files
      restored = approved["0"]
      assert restored["path"] == Path.expand(item.media_filepath)
      assert restored["sha256"] == sha256_of(item.media_filepath)
      refute Map.has_key?(restored, "stat")
    end
  end

  describe "durable restore hold and approvals" do
    @describetag :destructive_watch

    test "an unverified temporary leaves a persisted hold reason after recovery" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      File.write!(temporary, "truncated")
      {archive_file, media_file} = watched_archive_role(watch, "media")

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => media_file["sha256"],
                     "size" => media_file["size"]
                   }
                 ]
               })

      MediaWatch.recover_pending()

      # The rollback must not discard the hold it just decided to take.
      assert Repo.get!(Watch, watch.id).hold_reason == "unverified_restore_temporary"
      assert File.read!(temporary) == "truncated"
      assert File.stat!(archive_file).size == media_file["size"]
    end

    test "an unverified restore hold is generation-fenced and does not clear a successor lease" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      File.write!(temporary, "truncated")
      {_archive_file, media_file} = watched_archive_role(watch, "media")

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => media_file["sha256"],
                     "size" => media_file["size"]
                   }
                 ]
               })

      parent = self()

      MediaWatch.recover_pending(
        before_restore_hold: fn _watch_id ->
          {:ok, successor_lease} = MediaWatch.claim_lease(item.id, "replace")
          send(parent, {:successor_lease, successor_lease})
        end
      )

      assert_received {:successor_lease, successor_lease}
      assert MediaWatch.lease_current?(successor_lease)

      reloaded = Repo.get!(Watch, watch.id)
      # The successor advanced the generation, so the recovery's hold update was
      # fenced out instead of clearing a lease it no longer owned.
      assert reloaded.lease_owner == successor_lease.owner
      refute reloaded.hold_reason == "unverified_restore_temporary"
      assert File.read!(temporary) == "truncated"
    end

    test "approvals merge by file identity without numeric key collisions and permit next replacement" do
      {item, watch} = watched_item()
      original_media = File.read!(item.media_filepath)
      original_thumbnail = File.read!(item.thumbnail_filepath)
      [subtitle_entry] = item.subtitle_filepaths
      subtitle_path = List.last(subtitle_entry)

      existing = Repo.get!(Watch, watch.id).approved_active_files
      first = existing["first"]

      by_path =
        existing
        |> Map.delete("first")
        |> Map.values()
        |> Map.new(&{Path.expand(&1["path"]), &1})

      media = Map.fetch!(by_path, Path.expand(item.media_filepath))
      thumbnail = Map.fetch!(by_path, Path.expand(item.thumbnail_filepath))
      subtitle = Map.fetch!(by_path, Path.expand(subtitle_path))

      # Deliberately reverse the natural ordering: the sidecar occupies key "0"
      # and the media key "1". A merge keyed by numeric index would overwrite the
      # untouched sidecar when the restore publishes the media file.
      custom_approvals = %{"0" => thumbnail, "1" => media, "2" => subtitle, "first" => first}
      watch |> Ecto.Changeset.change(approved_active_files: custom_approvals) |> Repo.update!()

      File.rm!(item.media_filepath)

      assert {:ok, _restored} = MediaWatch.restore_active_from_archive(item)

      assert File.read!(item.media_filepath) == original_media
      assert File.read!(item.thumbnail_filepath) == original_thumbnail

      approvals = Repo.get!(Watch, watch.id).approved_active_files
      media_path = Path.expand(item.media_filepath)
      thumbnail_path = Path.expand(item.thumbnail_filepath)

      assert Enum.any?(approvals, fn {_key, file} -> file["path"] == media_path end)
      assert Enum.any?(approvals, fn {_key, file} -> file["path"] == thumbnail_path end)

      # The surviving approvals still identify the same files, so the next
      # replacement is still permitted.
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact 2")

      assert {:ok, updated} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _attrs -> Media.update_media_item(item, %{title: "next replacement"}) end
               )

      assert updated.title == "next replacement"
      assert File.read!(item.media_filepath) == "replacement artifact 2"
    end

    test "a restore keeps approvals for files it did not touch" do
      {item, watch} = watched_item()
      before_approvals = Repo.get!(Watch, watch.id).approved_active_files
      assert map_size(before_approvals) > 1

      File.rm!(item.media_filepath)

      assert {:ok, _item} = MediaWatch.restore_active_from_archive(item)
      assert File.read!(item.media_filepath) == "first artifact"

      after_approvals = Repo.get!(Watch, watch.id).approved_active_files
      media_path = Path.expand(item.media_filepath)

      assert Enum.any?(after_approvals, fn {_k, file} -> file["path"] == media_path end),
             "the restored media file must be approved"

      Enum.each(before_approvals, fn {_key, file} ->
        if file["path"] != media_path do
          assert Enum.any?(
                   after_approvals,
                   fn {_k, kept} ->
                     kept["path"] == file["path"] and kept["sha256"] == file["sha256"]
                   end
                 ),
                 "approval for #{file["path"]} was discarded by the restore"
        end
      end)
    end

    test "a partial restore interrupted between two files is reconciled on retry" do
      {item, watch} = watched_item()
      sidecar = item.thumbnail_filepath
      before_approvals = Repo.get!(Watch, watch.id).approved_active_files

      File.rm!(item.media_filepath)
      File.rm!(sidecar)

      {media_source, media_file} = watched_archive_role(watch, "media")
      {sidecar_source, sidecar_file} = watched_archive_role(watch, "thumbnail")

      operation_id = Ecto.UUID.generate()
      media_temp = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      sidecar_temp = sidecar <> ".pinchflat-restore-" <> operation_id

      # File 1 was published before the crash; file 2 was never copied.
      File.cp!(media_source, item.media_filepath)

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => media_temp,
                     "sha256" => media_file["sha256"],
                     "size" => media_file["size"]
                   },
                   %{
                     "role" => "thumbnail",
                     "path" => sidecar,
                     "temporary" => sidecar_temp,
                     "sha256" => sidecar_file["sha256"],
                     "size" => sidecar_file["size"]
                   }
                 ]
               })

      # File 2's verified copy is still on disk, so reconciliation publishes it.
      File.cp!(sidecar_source, sidecar_temp)

      assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id and &1.action == :restore_reconciled))

      media_path = Path.expand(item.media_filepath)
      sidecar_path = Path.expand(sidecar)
      approvals = Repo.get!(Watch, watch.id).approved_active_files

      # File 1, published before the crash, is claimed as restored rather than
      # silently dropped from the approvals.
      assert Enum.any?(approvals, fn {_k, file} ->
               file["path"] == media_path and file["sha256"] == media_file["sha256"]
             end)

      # File 2 is published by the retry and approved too.
      assert File.read!(sidecar) == File.read!(sidecar_source)

      assert Enum.any?(approvals, fn {_k, file} ->
               file["path"] == sidecar_path and file["sha256"] == sidecar_file["sha256"]
             end)

      # Approvals that predate the restore are preserved.
      Enum.each(before_approvals, fn {_key, old} ->
        assert Enum.any?(approvals, fn {_k, kept} -> kept["path"] == old["path"] end),
               "approval for #{old["path"]} was discarded"
      end)

      refute File.exists?(sidecar_temp)
      refute ReplacementIntent.restore_pending?(watch.id)
    end
  end

  describe "restore publication preserves operator files" do
    @describetag :destructive_watch

    test "a destination that appears in place of the temporary is never claimed as restored" do
      {item, watch} = watched_item()
      before_approvals = Repo.get!(Watch, watch.id).approved_active_files
      File.rm!(item.media_filepath)
      File.write!(item.media_filepath, "operator edit")

      {media_source, media_file} = watched_archive_role(watch, "media")
      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      File.cp!(media_source, temporary)

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => media_file["sha256"],
                     "size" => media_file["size"]
                   }
                 ]
               })

      MediaWatch.recover_pending()

      assert File.read!(item.media_filepath) == "operator edit"
      refute File.exists?(temporary)

      media_path = Path.expand(item.media_filepath)
      edit_hash = :sha256 |> :crypto.hash("operator edit") |> Base.encode16(case: :lower)

      # The operator's bytes are never approved, and no approval is invented for
      # a path this restore did not publish.
      refute Enum.any?(Repo.get!(Watch, watch.id).approved_active_files, fn {_k, file} ->
               file["path"] == media_path and file["sha256"] == edit_hash
             end),
             "an operator file must never be approved as the restored archive"

      assert Repo.get!(Watch, watch.id).approved_active_files == before_approvals
      assert sha256_of(item.media_filepath) == edit_hash
      assert File.stat!(media_source).size == media_file["size"]
    end

    test "normal restore atomically refuses to overwrite a destination created after existence check" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      assert {:error, :destination_occupied} =
               MediaWatch.restore_active_from_archive(item,
                 before_restore_publish: fn target -> File.write!(target, "user occupied this file") end
               )

      assert File.read!(item.media_filepath) == "user occupied this file"
      assert ReplacementIntent.restore_pending?(watch.id)
    end

    test "boot recovery atomically refuses to overwrite a destination created after existence check" do
      {item, watch} = watched_item()
      File.rm!(item.media_filepath)

      operation_id = Ecto.UUID.generate()
      temporary = item.media_filepath <> ".pinchflat-restore-" <> operation_id
      archive_file = watched_archive_media(watch)
      File.cp!(archive_file, temporary)

      assert {:ok, _} =
               ReplacementIntent.publish_restore(watch.id, %{
                 "operation_id" => operation_id,
                 "entries" => [
                   %{
                     "role" => "media",
                     "path" => item.media_filepath,
                     "temporary" => temporary,
                     "sha256" => sha256_of(temporary),
                     "size" => File.stat!(temporary).size
                   }
                 ]
               })

      assert [%{watch_id: watch_id, action: :needs_recovery}] =
               Enum.filter(
                 MediaWatch.recover_pending(
                   before_restore_publish: fn target -> File.write!(target, "user occupied on boot") end
                 ),
                 &(&1.watch_id == watch.id)
               )

      assert watch_id == watch.id
      assert File.read!(item.media_filepath) == "user occupied on boot"
      assert ReplacementIntent.restore_pending?(watch.id)
    end
  end

  describe "concurrency guarantees" do
    @describetag :destructive_watch

    # Process A pauses inside the hashing phase, which runs outside the write
    # transaction. A separate process with its own pooled connection must be able
    # to commit a write while A is paused; being blocked would mean A holds the
    # database write lock during filesystem work.
    @tag :unboxed
    test "an independent database writer is not blocked by a paused verification phase" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        uuid = Ecto.UUID.generate()

        profile =
          media_profile_fixture(%{name: "Writer Profile #{uuid}"})
          |> Ecto.Changeset.change(watch_window_days: 14)
          |> Repo.update!()

        source =
          %Pinchflat.Sources.Source{}
          |> Pinchflat.Sources.Source.changeset(
            %{
              enabled: true,
              collection_name: "Writer Channel #{uuid}",
              collection_id: "UC_writer_#{uuid}",
              collection_type: :channel,
              custom_name: "Writer Channel",
              original_url: "https://www.youtube.com/channel/UC_writer_#{uuid}",
              media_profile_id: profile.id,
              download_media: true,
              fast_index: false,
              index_frequency_minutes: 60
            },
            :pre_insert
          )
          |> Repo.insert!()

        item =
          media_item_with_attachments(%{
            source_id: source.id,
            metadata_filepath: nil,
            nfo_filepath: nil
          })

        File.write!(item.media_filepath, "first artifact")

        {:ok, watch} =
          Pinchflat.MediaWatchFixtures.enroll_approved_watch(item, Repo.preload(source, :media_profile))

        {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(1, :day)})
        item = Repo.preload(Repo.reload!(item), [:metadata, source: :media_profile])
        {:ok, published} = MediaWatch.archive_original(watch, item)
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        {:ok, _watch} = published |> Ecto.Changeset.change(last_success_at: now, next_check_at: now) |> Repo.update()

        {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
        staged = staged_file("replacement artifact")
        media_path = Path.expand(item.media_filepath)
        parent = self()
        database = Application.fetch_env!(:pinchflat, Repo)[:database]
        adapter = Application.get_env(:pinchflat, Repo)[:adapter]

        writer =
          Task.async(fn ->
            receive do
              :start_write ->
                {elapsed_us, result} =
                  :timer.tc(fn ->
                    if adapter == Ecto.Adapters.SQLite3 do
                      {:ok, db} = Exqlite.Sqlite3.open(database)
                      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout = 2000;")

                      res =
                        Exqlite.Sqlite3.execute(
                          db,
                          "UPDATE media_items SET description = 'independent' WHERE id = '#{item.id}'"
                        )

                      :ok = Exqlite.Sqlite3.close(db)
                      res
                    else
                      case Media.update_media_item(Media.get_media_item!(item.id), %{description: "independent"}) do
                        {:ok, _} -> :ok
                        other -> other
                      end
                    end
                  end)

                {div(elapsed_us, 1000), result}
            end
          end)

        try do
          assert {:ok, _updated} =
                   MediaWatch.commit_replacement(
                     lease,
                     item,
                     %{source_map: %{staged => item.media_filepath}},
                     fn pre_images ->
                       stage_incoming!(staged, media_path, pre_images)
                       {:ok, %{"filepath" => media_path}}
                     end,
                     fn _json -> Media.update_media_item(item, %{title: "replacement"}) end,
                     before_verify: fn path ->
                       if Path.expand(path) == media_path do
                         send(writer.pid, :start_write)
                         assert {elapsed, :ok} = Task.await(writer, 5_000)
                         send(parent, {:writer_ms, elapsed})
                       end

                       :ok
                     end
                   )

          assert_received {:writer_ms, elapsed}
          assert elapsed < 500, "independent write took #{elapsed}ms while verification was paused"
          assert Repo.reload!(item).description == "independent"
          refute ReplacementIntent.pending?(watch.id)
        after
          Repo.delete_all(from e in Pinchflat.MediaWatch.MediaWatchEvent, where: e.media_watch_id == ^watch.id)
          Repo.delete_all(from w in Watch, where: w.id == ^watch.id)
          Repo.delete!(item)
          Repo.delete!(source)
          Repo.delete!(profile)
          File.rm_rf!(Path.dirname(item.media_filepath))
        end
      end)
    end

    # The full-file digest checks run before the write reservation now. A writer
    # on its own SQLite connection must therefore commit immediately while those
    # reads are paused, instead of waiting out busy_timeout behind the lock the
    # old in-reservation hashing held.
    @tag :unboxed
    test "an independent database writer on a separate connection is not blocked during replacement file verification" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        uuid = Ecto.UUID.generate()

        profile =
          media_profile_fixture(%{name: "Verify Writer Profile #{uuid}"})
          |> Ecto.Changeset.change(watch_window_days: 14)
          |> Repo.update!()

        source =
          %Pinchflat.Sources.Source{}
          |> Pinchflat.Sources.Source.changeset(
            %{
              enabled: true,
              collection_name: "Verify Writer Channel #{uuid}",
              collection_id: "UC_verify_writer_#{uuid}",
              collection_type: :channel,
              custom_name: "Verify Writer Channel",
              original_url: "https://www.youtube.com/channel/UC_verify_writer_#{uuid}",
              media_profile_id: profile.id,
              download_media: true,
              fast_index: false,
              index_frequency_minutes: 60
            },
            :pre_insert
          )
          |> Repo.insert!()

        item =
          media_item_with_attachments(%{
            source_id: source.id,
            metadata_filepath: nil,
            nfo_filepath: nil
          })

        File.write!(item.media_filepath, "first artifact")

        {:ok, watch} =
          Pinchflat.MediaWatchFixtures.enroll_approved_watch(item, Repo.preload(source, :media_profile))

        {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(1, :day)})
        item = Repo.preload(Repo.reload!(item), [:metadata, source: :media_profile])
        {:ok, published} = MediaWatch.archive_original(watch, item)
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        {:ok, _watch} = published |> Ecto.Changeset.change(last_success_at: now, next_check_at: now) |> Repo.update()

        {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
        staged = staged_file("replacement artifact")
        media_path = Path.expand(item.media_filepath)
        parent = self()
        database = Application.fetch_env!(:pinchflat, Repo)[:database]
        adapter = Application.get_env(:pinchflat, Repo)[:adapter]

        writer =
          Task.async(fn ->
            receive do
              :start_write ->
                {elapsed_us, result} =
                  :timer.tc(fn ->
                    if adapter == Ecto.Adapters.SQLite3 do
                      {:ok, db} = Exqlite.Sqlite3.open(database)
                      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout = 500;")

                      res =
                        Exqlite.Sqlite3.execute(
                          db,
                          "UPDATE media_items SET description = 'independent' WHERE id = '#{item.id}'"
                        )

                      :ok = Exqlite.Sqlite3.close(db)
                      res
                    else
                      case Media.update_media_item(Media.get_media_item!(item.id), %{description: "independent"}) do
                        {:ok, _} -> :ok
                        other -> other
                      end
                    end
                  end)

                {div(elapsed_us, 1000), result}
            end
          end)

        try do
          assert {:ok, _updated} =
                   MediaWatch.commit_replacement(
                     lease,
                     item,
                     %{source_map: %{staged => item.media_filepath}},
                     fn pre_images ->
                       stage_incoming!(staged, media_path, pre_images)
                       {:ok, %{"filepath" => media_path}}
                     end,
                     fn _json -> Media.update_media_item(item, %{title: "replacement"}) end,
                     before_file_verify: fn path ->
                       if Path.expand(path) == media_path do
                         send(writer.pid, :start_write)
                         assert {elapsed, :ok} = Task.await(writer, 5_000)
                         send(parent, {:writer_ms, elapsed})
                       end

                       :ok
                     end
                   )

          assert_received {:writer_ms, elapsed}
          assert elapsed < 500, "independent write took #{elapsed}ms during file verification"
          assert Repo.reload!(item).description == "independent"
          refute ReplacementIntent.pending?(watch.id)
        after
          Repo.delete_all(from e in Pinchflat.MediaWatch.MediaWatchEvent, where: e.media_watch_id == ^watch.id)
          Repo.delete_all(from w in Watch, where: w.id == ^watch.id)
          Repo.delete!(item)
          Repo.delete!(source)
          Repo.delete!(profile)
          File.rm_rf!(Path.dirname(item.media_filepath))
        end
      end)
    end
  end

  describe "lease heartbeat and swap ownership" do
    @describetag :destructive_watch

    test "a replacement slower than the lease window succeeds when heartbeats keep ownership" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace", lease_seconds: 1)
      staged = staged_file("replacement artifact")

      assert {:ok, updated} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   # A transfer far longer than the original one-second lease.
                   Process.sleep(1_500)
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> Media.update_media_item(item, %{title: "slow replacement"}) end
               )

      assert Repo.reload!(updated).title == "slow replacement"
      assert File.read!(item.media_filepath) == "replacement artifact"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a slow owner superseded by a successor fails closed without corrupting the destination" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :watch_hold} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("a superseded worker must not update the media item") end,
                 before_swap: fn ->
                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id), inc: [lease_generation: 1])
                 end
               )

      assert File.read!(item.media_filepath) == original
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      assert Repo.get!(Watch, watch.id).operation_id == nil
    end

    test "an active file edited between verification and commit fails closed" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :active_file_changed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("an edited active file must never be approved") end,
                 before_swap: fn -> File.write!(item.media_filepath, "edited after verification") end
               )

      # The edit is neither approved nor left in place: recovery restores the
      # verified original, and the staged replacement is quarantined.
      refute ReplacementIntent.pending?(watch.id)
      assert File.read!(item.media_filepath) == "first artifact"

      approved = Repo.get!(Watch, watch.id).approved_active_files

      edited_hash = :sha256 |> :crypto.hash("edited after verification") |> Base.encode16(case: :lower)

      assert Enum.all?(
               Map.delete(approved, "first"),
               fn {_k, file} -> file["sha256"] != edited_hash end
             )
    end

    test "a live heartbeat keeps a second worker out for the whole slow transfer" do
      {item, watch} = watched_item()
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace", lease_seconds: 2)
      staged = staged_file("replacement artifact")
      original = File.read!(item.media_filepath)
      parent = self()

      takeover =
        Task.async(fn ->
          receive do
            :try_takeover -> MediaWatch.claim_lease(item.id, "replace")
          end
        end)

      assert {:ok, updated} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   # Far longer than the two-second lease, with no heartbeat
                   # injected here: only the production loop keeps ownership.
                   Process.sleep(2_500)

                   send(takeover.pid, :try_takeover)
                   send(parent, {:takeover, Task.await(takeover, 5_000)})
                   send(parent, {:active_during_pause, File.read!(item.media_filepath)})

                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> Media.update_media_item(item, %{title: "slow owner"}) end
               )

      assert_received {:takeover, {:error, :lease_busy}}
      assert_received {:active_during_pause, paused_bytes}
      assert paused_bytes == original
      assert Repo.reload!(updated).title == "slow owner"
      assert File.read!(item.media_filepath) == "replacement artifact"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
    end

    test "a lease that expires without heartbeats is superseded and the worker is rejected" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      {:ok, lease_a} = MediaWatch.claim_lease(item.id, "replace", lease_seconds: 1)
      staged = staged_file("worker a artifact")

      assert {:error, outcome} =
               MediaWatch.commit_replacement(
                 lease_a,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   # No heartbeat: worker B deterministically takes the watch once
                   # the deadline has passed, which bumps the generation.
                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
                     set: [lease_expires_at: now_minus(1, :minute)]
                   )

                   assert {:ok, lease_b} = MediaWatch.claim_lease(item.id, "replace")
                   assert lease_b.generation > lease_a.generation
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("a superseded worker must not commit") end
               )

      assert outcome in [:watch_hold, :lost_lease]

      assert File.read!(item.media_filepath) == original
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
    end

    test "a worker paused before the swap cannot publish after a successor advances the lease" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      {:ok, lease_a} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("worker a artifact")

      assert {:error, outcome} =
               MediaWatch.commit_replacement(
                 lease_a,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("worker A must never commit after losing ownership") end,
                 before_swap: fn ->
                   # Worker B recovers the abandoned journal and takes a new generation.
                   Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
                     set: [lease_expires_at: now_minus(1, :minute)]
                   )

                   assert Enum.any?(MediaWatch.recover_pending(), &(&1.watch_id == watch.id))
                   assert {:ok, _} = MediaWatch.claim_lease(item.id, "replace")
                 end
               )

      assert outcome in [:watch_hold, :lost_lease, :replacement_in_progress]
      assert File.read!(item.media_filepath) == original
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))

      ownership = Repo.get!(Watch, watch.id)
      assert is_nil(ownership.operation_id) or ownership.operation_id != lease_a.owner
    end

    test "a same-size content edit with unchanged modification timestamp before swap fails closed" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      assert byte_size(original) == 14
      original_stat = File.lstat!(item.media_filepath, time: :posix)

      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :active_file_changed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("a changed active file must never be approved") end,
                 before_swap: fn ->
                   # Keep the byte count, inode, and recorded mtime unchanged.
                   File.write!(item.media_filepath, "second artifac")
                   File.touch!(item.media_filepath, original_stat.mtime)

                   edited_stat = File.lstat!(item.media_filepath, time: :posix)

                   assert edited_stat.size == original_stat.size and
                            edited_stat.inode == original_stat.inode and
                            edited_stat.mtime == original_stat.mtime
                 end
               )

      # Recovery restores the verified original and preserves the edit.
      assert File.read!(item.media_filepath) == original
      refute ReplacementIntent.pending?(watch.id)
      assert File.stat!(item.media_filepath).size == original_stat.size

      [directory] = Enum.filter(File.ls!(quarantine_root()), &String.starts_with?(&1, "quarantine-#{watch.id}-"))

      quarantined =
        quarantine_root()
        |> Path.join(directory)
        |> File.ls!()
        |> Enum.map(&File.read!(Path.join([quarantine_root(), directory, &1])))

      assert "second artifac" in quarantined

      edited_hash = :sha256 |> :crypto.hash("second artifac") |> Base.encode16(case: :lower)

      refute Enum.any?(Repo.get!(Watch, watch.id).approved_active_files, fn {_key, file} ->
               is_map(file) and file["sha256"] == edited_hash
             end)
    end

    test "a same-size content edit to the incoming media with unchanged modification timestamp before swap fails closed" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      parent = self()

      # Before the fix, approve_entry hashed the incoming file and the swap only
      # re-checked its type. A same-size edit that kept the inode and restored
      # mtime was then renamed into place while the database saved the old hash.
      assert {:error, :active_file_changed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   incoming = stage_incoming!(staged, item.media_filepath, pre_images)
                   send(parent, {:incoming, incoming})
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json -> flunk("edited incoming bytes must never be approved") end,
                 before_swap: fn ->
                   assert_received {:incoming, incoming}

                   incoming_stat = File.lstat!(incoming, time: :posix)
                   assert File.read!(incoming) == "replacement artifact"

                   # Same byte count, different bytes, original mtime restored.
                   File.write!(incoming, "replacement artifacX")
                   File.touch!(incoming, incoming_stat.mtime)

                   edited_stat = File.lstat!(incoming, time: :posix)

                   assert edited_stat.size == incoming_stat.size
                   assert edited_stat.inode == incoming_stat.inode
                   assert edited_stat.mtime == incoming_stat.mtime
                 end
               )

      # The active original is untouched and still recoverable, the journal is
      # cleared by a successful recovery, and the failure is reported as itself
      # rather than wrapped in a recovery error.
      assert File.read!(item.media_filepath) == original
      refute ReplacementIntent.pending?(watch.id)
      assert {:ok, _manifest} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))

      edited_hash = :sha256 |> :crypto.hash("replacement artifacX") |> Base.encode16(case: :lower)

      refute Enum.any?(Repo.get!(Watch, watch.id).approved_active_files, fn {_key, file} ->
               is_map(file) and file["sha256"] == edited_hash
             end),
             "modified incoming bytes must never be approved"
    end

    test "a same-size edit after the swap rolls back approval and preserves both copies" do
      {item, watch} = watched_item()
      original = File.read!(item.media_filepath)
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")
      edited = "replacement artifacX"

      assert {:error, :active_file_changed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _json ->
                   assert File.read!(item.media_filepath) == "replacement artifact"
                   assert {:ok, %{"mtime" => mtime} = stamp} = ReplacementIntent.file_stamp(item.media_filepath)
                   File.write!(item.media_filepath, edited)
                   assert {"", 0} = System.cmd("touch", ["-m", "-d", mtime, "--", item.media_filepath])
                   assert {:ok, edited_stamp} = ReplacementIntent.file_stamp(item.media_filepath)
                   assert Map.delete(edited_stamp, "ctime") == Map.delete(stamp, "ctime")
                   assert edited_stamp["ctime"] != stamp["ctime"]
                   Media.update_media_item(item, %{title: "must roll back"})
                 end
               )

      assert Repo.reload!(item).title == item.title
      assert File.read!(item.media_filepath) == original
      assert File.read!(watched_archive_media(watch)) == original
      refute ReplacementIntent.pending?(watch.id)

      assert Enum.any?(Path.wildcard(Path.join(quarantine_root(), "quarantine-#{watch.id}-*/*")), fn path ->
               File.read!(path) == edited
             end)
    end
  end

  describe "cross-filesystem quarantine and recovery" do
    @describetag :destructive_watch

    setup do
      original = Application.fetch_env!(:pinchflat, :metadata_directory)
      directory = Path.join("/dev/shm", "pinchflat-quarantine-#{Ecto.UUID.generate()}")
      File.mkdir_p!(directory)
      Application.put_env(:pinchflat, :metadata_directory, directory)
      File.rm_rf!(quarantine_root())
      File.mkdir_p!(quarantine_root())

      assert File.stat!(directory).major_device !=
               File.stat!(Application.fetch_env!(:pinchflat, :media_directory)).major_device

      on_exit(fn ->
        Application.put_env(:pinchflat, :metadata_directory, original)
        File.rm_rf!(directory)
        File.rm_rf!(quarantine_root())
      end)

      %{internal_thumbnail: Path.join(directory, "thumbnail.jpg")}
    end

    test "quarantines across devices without replacing an existing saved copy", %{internal_thumbnail: path} do
      File.write!(path, "new thumbnail")
      operation = Ecto.UUID.generate()
      assert {:ok, [saved]} = ReplacementIntent.quarantine(219, operation, [path])
      assert File.read!(saved) == "new thumbnail"
      refute File.exists?(path)
      assert Path.dirname(saved) |> File.ls!() == [Path.basename(saved)]

      File.write!(path, "another thumbnail")
      assert {:error, :quarantine_destination_exists} = ReplacementIntent.quarantine(219, operation, [path])
      assert File.read!(saved) == "new thumbnail"
      assert File.read!(path) == "another thumbnail"
    end

    test "a source changed after publication is retained beside the verified quarantine copy", %{
      internal_thumbnail: path
    } do
      File.write!(path, "original thumbnail")
      original_path = System.fetch_env!("PATH")
      sync = System.find_executable("sync")
      directory = Path.join(System.tmp_dir!(), "quarantine-sync-#{Ecto.UUID.generate()}")
      File.mkdir_p!(directory)
      executable = Path.join(directory, "sync")

      File.write!(executable, "#!/bin/sh\nprintf 'edited thumbnail' > #{inspect(path)}\nexec #{inspect(sync)} \"$@\"\n")
      File.chmod!(executable, 0o755)
      System.put_env("PATH", directory <> ":" <> original_path)

      try do
        assert {:error, :quarantine_source_changed} = ReplacementIntent.quarantine(219, Ecto.UUID.generate(), [path])
        assert File.read!(path) == "edited thumbnail"

        [saved_directory] =
          quarantine_root()
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, "quarantine-219-"))

        [saved] = File.ls!(Path.join(quarantine_root(), saved_directory))
        assert File.read!(Path.join([quarantine_root(), saved_directory, saved])) == "original thumbnail"
        refute String.contains?(saved, ".copy-")
      after
        System.put_env("PATH", original_path)
        File.rm_rf!(directory)
      end
    end

    test "an inline queued restore completes the job and leaves the item playable", %{
      internal_thumbnail: _path
    } do
      profile =
        media_profile_fixture()
        |> Ecto.Changeset.change(watch_window_days: 14)
        |> Repo.update!()

      source = source_fixture(%{media_profile_id: profile.id})

      item =
        media_item_with_attachments(%{source_id: source.id, metadata_filepath: nil, nfo_filepath: nil})

      # Generate real playable video before enrollment
      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "testsrc=duration=2:size=320x240:rate=1",
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          item.media_filepath
        ])

      assert {probe, 0} =
               System.cmd("ffprobe", [
                 "-v",
                 "error",
                 "-show_entries",
                 "format=duration",
                 "-of",
                 "default=noprint_wrappers=1:nokey=1",
                 item.media_filepath
               ])

      assert String.to_float(String.trim(probe)) > 0.0

      {:ok, watch} = Pinchflat.MediaWatchFixtures.enroll_approved_watch(item, Repo.preload(source, :media_profile))
      {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(1, :day)})

      item = Repo.preload(Repo.reload(item), [:metadata, source: :media_profile])
      {:ok, published_watch} = MediaWatch.archive_original(watch, item)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, watch} =
        published_watch
        |> Ecto.Changeset.change(last_success_at: now, next_check_at: now)
        |> Repo.update()

      original = File.read!(item.media_filepath)
      File.rm!(item.media_filepath)
      {:ok, _} = Media.update_media_item(item, %{last_error: "missing active media"})
      mock_replacement_download(Repo.reload(item))

      {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: item.id, force: true}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :media_fetching)

      # Read back the terminal state directly from the database
      terminal_job = Repo.get!(Oban.Job, job.id)
      assert terminal_job.state == "completed"

      restored = Repo.reload!(item)
      assert File.read!(item.media_filepath) == original
      assert is_nil(restored.last_error)
      assert File.regular?(item.media_filepath)

      # Verify the restored file is a valid playable video via ffprobe
      assert {restored_probe, 0} =
               System.cmd("ffprobe", [
                 "-v",
                 "error",
                 "-show_entries",
                 "format=duration",
                 "-of",
                 "default=noprint_wrappers=1:nokey=1",
                 item.media_filepath
               ])

      assert String.to_float(String.trim(restored_probe)) > 0.0
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a failed replacement restores config thumbnails and can subsequently complete", %{internal_thumbnail: path} do
      File.write!(path, "original thumbnail")
      File.write!(path <> ".json.gz", :zlib.gzip("{}"))
      {item, watch} = watched_item(%{metadata: %{thumbnail_filepath: path, metadata_filepath: path <> ".json.gz"}})
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      staged = staged_file("replacement artifact")

      assert {:error, :transfer_failed} =
               MediaWatch.commit_replacement(
                 lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn _ ->
                   File.write!(item.media_filepath, "incomplete replacement")
                   File.write!(path, "incomplete thumbnail")
                   {:error, :transfer_failed}
                 end,
                 fn _ -> flunk("failed transfers must not update the item") end
               )

      assert File.read!(item.media_filepath) == "first artifact"
      assert File.read!(path) == "original thumbnail"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)

      [quarantine] = Enum.filter(File.ls!(quarantine_root()), &String.starts_with?(&1, "quarantine-"))

      assert quarantine_root()
             |> Path.join(quarantine)
             |> File.ls!()
             |> Enum.map(&File.read!(Path.join([quarantine_root(), quarantine, &1])))
             |> Enum.sort() == ["incomplete replacement", "incomplete thumbnail"]

      :ok = MediaWatch.finish_replacement(lease)
      {:ok, retry_lease} = MediaWatch.prepare_replacement(Repo.preload(item, source: :media_profile))

      assert {:ok, updated} =
               MediaWatch.commit_replacement(
                 retry_lease,
                 item,
                 %{source_map: %{staged => item.media_filepath}},
                 fn pre_images ->
                   stage_incoming!(staged, item.media_filepath, pre_images)
                   {:ok, %{"filepath" => item.media_filepath}}
                 end,
                 fn _prepared -> Media.update_media_item(item, %{title: "Completed replacement"}) end,
                 prepare: fn transferred ->
                   # Regenerated sidecars are written beside the destination and
                   # published by the swap, never over the active file.
                   File.write!(path <> transferred["incoming_suffix"], "completed thumbnail")
                   {:ok, transferred}
                 end
               )

      assert Repo.reload!(updated).title == "Completed replacement"
      assert File.read!(item.media_filepath) == "replacement artifact"
      assert File.read!(path) == "completed thumbnail"
      assert {:ok, _} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
      refute ReplacementIntent.pending?(watch.id)
    end

    test "a full quarantine filesystem keeps the source and removes the partial copy", %{internal_thumbnail: path} do
      original_media = Application.fetch_env!(:pinchflat, :media_directory)
      destination_root = Path.dirname(path)
      Application.put_env(:pinchflat, :media_directory, destination_root)
      source = Path.join(Application.fetch_env!(:pinchflat, :extras_directory), "full-disk-#{Ecto.UUID.generate()}")

      try do
        {output, 0} = System.cmd("df", ["--output=avail", "-B1", destination_root])
        available = output |> String.split() |> List.last() |> String.to_integer()
        chunk = :binary.copy("x", 1024 * 1024)

        File.open!(source, [:write, :binary], fn file ->
          for _ <- 0..div(available, byte_size(chunk)), do: :ok = :file.write(file, chunk)
        end)

        assert {:ok, expected} = ReplacementIntent.fingerprint(source)
        assert {:error, :enospc} = ReplacementIntent.quarantine(219, "full-disk", [source])
        assert {:ok, ^expected} = ReplacementIntent.fingerprint(source)
        [directory] = File.ls!(quarantine_root())
        assert File.ls!(Path.join(quarantine_root(), directory)) == []
      after
        Application.put_env(:pinchflat, :media_directory, original_media)
        File.rm(source)
      end
    end
  end

  defp watched_item(attrs \\ %{}) do
    profile =
      media_profile_fixture()
      |> Ecto.Changeset.change(watch_window_days: 14)
      |> Repo.update!()

    source = source_fixture(%{media_profile_id: profile.id})

    item =
      media_item_with_attachments(Map.merge(%{source_id: source.id, metadata_filepath: nil, nfo_filepath: nil}, attrs))

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

  defp enqueue_force_download(item) do
    build_conn() |> post("/api/media/#{item.id}/actions/download") |> json_response(200)
    [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})
    job
  end

  defp mock_replacement_download(item) do
    media_root = Application.fetch_env!(:pinchflat, :media_directory) |> Path.expand()
    relative_directory = Path.relative_to(Path.dirname(item.media_filepath), media_root)

    stub(UserScriptRunnerMock, :run, fn _event, _item -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

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

  defp no_restore_copies?(path) do
    path
    |> Path.dirname()
    |> File.ls!()
    |> Enum.all?(&(not String.starts_with?(&1, Path.basename(path) <> ".pinchflat-restore-")))
  end

  # Mimics the production transfer: staged bytes become the incoming copy beside
  # the destination, leaving the active file untouched until the swap.
  defp stage_incoming!(staged, destination, pre_images) do
    incoming = DownloadStaging.incoming_path(destination, pre_images[destination])
    File.rm(incoming)
    File.rename!(staged, incoming)
    incoming
  end

  defp sha256_of(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp watched_archive_media(watch), do: watch |> watched_archive_role("media") |> elem(0)

  defp watched_archive_role(watch, role) do
    manifest_path = OriginalArchive.relative_manifest_path(watch.id)

    {:ok, absolute} = OriginalArchive.resolve_manifest_path(manifest_path)
    {:ok, manifest} = OriginalArchive.verify(absolute, watch_id: watch.id)

    file = Enum.find(manifest["files"], &(&1["role"] == role))
    {Path.join(Path.dirname(absolute), file["path"]), file}
  end

  defp quarantine_root do
    Path.join(Application.fetch_env!(:pinchflat, :media_directory), ".pinchflat-replacements")
  end
end
