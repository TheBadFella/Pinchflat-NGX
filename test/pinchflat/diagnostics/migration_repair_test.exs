defmodule Pinchflat.Diagnostics.MigrationRepairTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Diagnostics.MigrationRepair
  alias Pinchflat.Repo
  alias Pinchflat.Sources

  describe "preview_restore_source_names/2" do
    test "builds bounded preview proposals without mutating database, preserving lock state by default" do
      s1 = source_fixture(%{custom_name: "Overwritten Name 1", custom_name_locked: false})
      s2 = source_fixture(%{custom_name: "Original Name 2", custom_name_locked: true})

      backup = [
        %{"id" => s1.id, "custom_name" => "True Original Name 1"},
        %{"id" => s2.id, "custom_name" => "Original Name 2"},
        %{"id" => 99_999, "custom_name" => "Ghost Channel"}
      ]

      {:ok, preview} = MigrationRepair.preview_restore_source_names(backup)

      assert preview.total_proposals == 1
      assert length(preview.to_update) == 1
      proposal = hd(preview.to_update)
      assert proposal.id == s1.id
      assert proposal.current_name == "Overwritten Name 1"
      assert proposal.proposed_name == "True Original Name 1"
      # Lock state preserved by default per R147-1
      assert proposal.will_lock == false

      # S2 already matches
      assert Enum.any?(preview.already_matching, &(&1.id == s2.id))

      # 99999 is not found
      assert Enum.any?(preview.not_found, &(&1.id == 99_999))

      # DB state remains completely untouched
      assert Repo.reload!(s1).custom_name == "Overwritten Name 1"
    end

    test "respects explicit lock: true option" do
      s1 = source_fixture(%{custom_name: "Overwritten Name", custom_name_locked: false})
      backup = [%{"id" => s1.id, "custom_name" => "True Original Name"}]

      {:ok, preview} = MigrationRepair.preview_restore_source_names(backup, lock: true)

      assert preview.total_proposals == 1
      proposal = hd(preview.to_update)
      assert proposal.will_lock == true
    end

    test "rejects proposals with collection_id mismatch per R147-4" do
      s1 = source_fixture(%{custom_name: "Current Collection", collection_id: "col-123"})
      backup = [%{"id" => s1.id, "custom_name" => "Wrong Collection", "collection_id" => "col-999"}]

      {:ok, preview} = MigrationRepair.preview_restore_source_names(backup)

      assert preview.total_proposals == 0
      assert length(preview.mismatched_identity) == 1
      mismatch = hd(preview.mismatched_identity)
      assert mismatch.reason == :collection_id_mismatch
    end

    test "rejects blank or whitespace names" do
      s1 = source_fixture(%{custom_name: "Some Name"})
      backup = [%{"id" => s1.id, "custom_name" => "   "}]

      {:ok, preview} = MigrationRepair.preview_restore_source_names(backup)

      assert preview.total_proposals == 0
      assert length(preview.invalid_names) == 1
    end
  end

  describe "apply_restore_source_names/2" do
    test "restores names preserving user lock state, skipping stale preview proposals" do
      s1 = source_fixture(%{custom_name: "Old Name 1", custom_name_locked: false})
      s2 = source_fixture(%{custom_name: "Old Name 2", custom_name_locked: false})

      backup = [
        %{id: s1.id, custom_name: "Restored Name 1"},
        %{id: s2.id, custom_name: "Restored Name 2"}
      ]

      {:ok, preview} = MigrationRepair.preview_restore_source_names(backup)

      # Concurrently modify s2 before apply to simulate stale preview
      {:ok, _} = Sources.update_source(s2, %{custom_name: "User Changed Name In Flight"})

      {:ok, result} = MigrationRepair.apply_restore_source_names(preview)

      assert result.applied == 1
      assert result.skipped == 1

      # S1 successfully updated while preserving unlocked status per R147-1
      s1_updated = Repo.reload!(s1)
      assert s1_updated.custom_name == "Restored Name 1"
      assert s1_updated.custom_name_locked == false

      # S2 was skipped because state became stale, preserving concurrent user edit
      s2_reloaded = Repo.reload!(s2)
      assert s2_reloaded.custom_name == "User Changed Name In Flight"
    end

    test "fails when preview has been cancelled per R147-2" do
      s1 = source_fixture(%{custom_name: "Old Name", custom_name_locked: false})
      backup = [%{id: s1.id, custom_name: "Restored Name"}]

      {:ok, preview} = MigrationRepair.preview_restore_source_names(backup)
      assert {:ok, :cancelled} = MigrationRepair.cancel_repair(preview)

      assert {:error, :cancelled} = MigrationRepair.apply_restore_source_names(preview)
      assert Repo.reload!(s1).custom_name == "Old Name"
    end

    test "is idempotent on repeated application" do
      s1 = source_fixture(%{custom_name: "Changed Name", custom_name_locked: false})
      backup = [%{id: s1.id, custom_name: "Restored Name"}]

      {:ok, preview1} = MigrationRepair.preview_restore_source_names(backup)
      {:ok, result1} = MigrationRepair.apply_restore_source_names(preview1)
      assert result1.applied == 1

      # Second preview should report already matching
      {:ok, preview2} = MigrationRepair.preview_restore_source_names(backup)
      assert preview2.total_proposals == 0
      assert Enum.any?(preview2.already_matching, &(&1.id == s1.id))
    end
  end

  describe "preview_protect_unlocked_sources/1 and apply_protect_unlocked_sources/1" do
    test "locks explicitly selected unlocked sources while preserving user choice" do
      s1 = source_fixture(%{custom_name: "Source 1", custom_name_locked: false})
      s2 = source_fixture(%{custom_name: "Source 2", custom_name_locked: false})

      # Only select s1 to protect
      {:ok, preview} = MigrationRepair.preview_protect_unlocked_sources([s1.id])
      assert preview.total_proposals == 1
      assert hd(preview.to_update).id == s1.id

      {:ok, result} = MigrationRepair.apply_protect_unlocked_sources(preview)
      assert result.applied == 1

      # s1 is locked, s2 remains unlocked per user choice
      assert Repo.reload!(s1).custom_name_locked == true
      assert Repo.reload!(s2).custom_name_locked == false
    end

    test "skips locking when source was edited concurrently per R147-3" do
      s1 = source_fixture(%{custom_name: "Original Name", custom_name_locked: false})

      {:ok, preview} = MigrationRepair.preview_protect_unlocked_sources([s1.id])

      # User edits source name concurrently
      Repo.update!(Ecto.Changeset.change(s1, custom_name: "New Name"))

      {:ok, result} = MigrationRepair.apply_protect_unlocked_sources(preview)
      assert result.skipped == 1
      assert result.applied == 0
      assert Repo.reload!(s1).custom_name_locked == false
    end
  end

  describe "cancel_repair/1" do
    test "cancels preview plan and registers cancelled status in TokenStore" do
      s1 = source_fixture(%{custom_name: "Source 1"})
      {:ok, preview} = MigrationRepair.preview_restore_source_names(%{s1.id => "New Name"})

      assert {:ok, :cancelled} = MigrationRepair.cancel_repair(preview)
      assert {:error, :cancelled} = MigrationRepair.apply_restore_source_names(preview)
    end
  end
end
