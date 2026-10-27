defmodule Pinchflat.MediaWatch.MutationTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.Profiles
  alias Pinchflat.Repo
  alias Pinchflat.Sources

  setup do
    on_exit(fn ->
      Application.delete_env(:pinchflat, :media_watch_destructive_enabled)
      File.rm_rf(OriginalArchive.root())
    end)

    :ok
  end

  describe "lease ownership" do
    test "grants one live owner per watch" do
      {_item, watch} = watched_media_item()

      assert {:ok, lease} = MediaWatch.claim_lease(watch.media_item_id, "replace")
      assert lease.generation == 1
      assert {:error, :lease_busy} = MediaWatch.claim_lease(watch.media_item_id, "replace")
      assert :ok = MediaWatch.renew_lease(lease)
      assert MediaWatch.lease_current?(lease)
    end

    test "an expired owner cannot renew and cannot clear a successor's lease" do
      {_item, watch} = watched_media_item()

      assert {:ok, first} = MediaWatch.claim_lease(watch.media_item_id, "replace", lease_seconds: -1)
      assert {:error, :lost_lease} = MediaWatch.renew_lease(first)

      assert {:ok, second} = MediaWatch.claim_lease(watch.media_item_id, "replace")
      assert second.generation == first.generation + 1

      assert :ok = MediaWatch.release_lease(first)
      assert MediaWatch.lease_current?(second)
    end
  end

  describe "replacement gate" do
    test "refuses while the execution gate is explicitly disabled and leaves the active file intact" do
      Application.put_env(:pinchflat, :media_watch_destructive_enabled, false)
      {item, watch} = watched_media_item()

      assert MediaWatch.replacement_blocked?(item.id)
      assert {:error, :watch_guard_unapproved} = MediaWatch.prepare_replacement(item)
      assert File.read!(item.media_filepath) == "first artifact"
      assert Repo.get!(Watch, watch.id).archive_state == "none"
    end

    test "unknown, stale, disabled, expired or manually held state stops replacement" do
      Application.put_env(:pinchflat, :media_watch_destructive_enabled, true)
      {item, watch} = watched_media_item()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.get!(Watch, watch.id)
      |> Ecto.Changeset.change(last_success_at: now)
      |> Repo.update!()

      refute MediaWatch.replacement_blocked?(item.id)

      for attrs <- [
            %{last_error_at: now},
            %{last_success_at: DateTime.add(now, -7 * 60 * 60, :second)},
            %{ends_at: DateTime.add(now, -1, :second)}
          ] do
        current = Repo.get!(Watch, watch.id)
        current |> Ecto.Changeset.change(attrs) |> Repo.update!()
        assert MediaWatch.replacement_blocked?(item.id)
        assert {:error, :watch_hold} = MediaWatch.prepare_replacement(item)

        current
        |> Ecto.Changeset.change(last_error_at: nil, last_success_at: now, ends_at: DateTime.add(now, 86_400, :second))
        |> Repo.update!()
      end

      item |> Ecto.Changeset.change(prevent_download: true) |> Repo.update!()
      assert MediaWatch.replacement_blocked?(item.id)
      item |> Ecto.Changeset.change(prevent_download: false, prevent_culling: true) |> Repo.update!()
      assert MediaWatch.replacement_blocked?(item.id)
      item |> Ecto.Changeset.change(prevent_culling: false) |> Repo.update!()

      source = Sources.get_source!(item.source_id)
      source |> Ecto.Changeset.change(watch_window_days: 0) |> Repo.update!()
      assert MediaWatch.replacement_blocked?(item.id)
    end

    test "refuses a held item even when the gate is enabled" do
      Application.put_env(:pinchflat, :media_watch_destructive_enabled, true)
      {item, watch} = watched_media_item()

      {:ok, _} =
        watch
        |> Ecto.Changeset.change(
          hold_reason: "suspected duration change",
          hold_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()

      assert MediaWatch.replacement_blocked?(item.id)
      assert {:error, :watch_hold} = MediaWatch.prepare_replacement(item)
      assert File.read!(item.media_filepath) == "first artifact"
    end
  end

  describe "active file deletion gate" do
    test "unwatched media keeps existing behavior" do
      item = media_item_with_attachments()

      assert :ok = MediaWatch.allow_active_file_deletion(item)
    end

    test "watched media fails closed with the gate disabled or before archive publication" do
      {item, watch} = watched_media_item()

      Application.put_env(:pinchflat, :media_watch_destructive_enabled, false)
      assert {:error, :watch_guard_unapproved} = MediaWatch.allow_active_file_deletion(item)

      Application.put_env(:pinchflat, :media_watch_destructive_enabled, true)
      assert {:error, :watch_archive_required} = MediaWatch.allow_active_file_deletion(item)
      assert Repo.get!(Watch, watch.id).archive_state == "none"
    end

    test "media deletion is refused for a watched item that has no verified original" do
      {item, _watch} = watched_media_item()

      assert {:error, :watch_hold} = Media.delete_media_files(item)
      assert File.exists?(item.media_filepath)
    end

    test "keep-files media/source/profile deletion cannot orphan a watched original" do
      {item, watch} = watched_media_item()
      source = Sources.get_source!(item.source_id)
      profile = Profiles.get_media_profile!(source.media_profile_id)

      assert {:error, :watch_tombstone_required} = Media.delete_media_item(item, delete_files: false)
      assert {:error, :watch_tombstone_required} = Sources.delete_source(source, delete_files: false)
      assert {:error, :watch_tombstone_required} = Sources.delete_source(source, delete_files: true)
      assert {:error, :watch_tombstone_required} = Profiles.delete_media_profile(profile, delete_files: false)
      assert {:error, :watch_tombstone_required} = Profiles.delete_media_profile(profile, delete_files: true)
      assert Repo.get!(Watch, watch.id).media_item_id == item.id
      assert File.read!(item.media_filepath) == "first artifact"
      assert Repo.get!(Pinchflat.Sources.Source, source.id)
    end

    test "watched media is allowed once a verified original is published" do
      Application.put_env(:pinchflat, :media_watch_destructive_enabled, true)
      {item, watch} = watched_media_item()

      assert {:ok, %{archive_state: "published"}} = MediaWatch.archive_original(watch, Repo.preload(item, :metadata))
      assert :ok = MediaWatch.allow_active_file_deletion(item)
      assert {:error, :watch_tombstone_required} = Media.delete_media_item(item, delete_files: true)
      assert {:error, :watch_tombstone_required} = Media.delete_media_item(item)
      assert Repo.get!(Watch, watch.id).media_item_id == item.id
      assert File.read!(item.media_filepath) == "first artifact"
      assert {:ok, _} = OriginalArchive.verify_relative(Repo.get!(Watch, watch.id).original_manifest_path)
    end
  end

  describe "retention protection" do
    test "an active watch or incident hold protects active files from retention" do
      {item, watch} = watched_media_item()

      refute Media.retention_cullable?(item)

      {:ok, _} =
        watch
        |> Ecto.Changeset.change(ends_at: now_minus(1, :day) |> DateTime.truncate(:second))
        |> Repo.update()

      assert Media.retention_cullable?(item)

      {:ok, _} =
        Repo.get!(Watch, watch.id)
        |> Ecto.Changeset.change(hold_reason: "confirmed change")
        |> Repo.update()

      refute Media.retention_cullable?(item)
    end
  end

  describe "recovery" do
    test "reconciles an interrupted publication when the archive is valid" do
      {item, watch} = watched_media_item()

      assert {:ok, %{manifest_path: manifest_path}} =
               OriginalArchive.publish(watch, Repo.preload(item, :metadata))

      {:ok, _} =
        watch
        |> Ecto.Changeset.change(archive_state: "preparing", original_manifest_path: manifest_path)
        |> Repo.update()

      assert [%{watch_id: watch_id, action: :published}] = MediaWatch.recover_pending()
      assert watch_id == watch.id
      assert Repo.get!(Watch, watch.id).archive_state == "published"
    end

    test "drops an unvalidated publication attempt without deleting a published archive" do
      {_item, watch} = watched_media_item()
      root = OriginalArchive.root()
      temporary = Path.join(root, ".preparing-#{watch.id}-interrupted")
      File.mkdir_p!(temporary)

      {:ok, _} =
        watch
        |> Ecto.Changeset.change(archive_state: "preparing")
        |> Repo.update()

      assert [%{action: :unarchived}] = MediaWatch.recover_pending()
      assert Repo.get!(Watch, watch.id).archive_state == "none"
      refute File.exists?(temporary)
    end
  end

  defp watched_media_item do
    profile = media_profile_fixture(%{retention_period_days: 2})

    profile =
      profile
      |> Ecto.Changeset.change(watch_window_days: 14)
      |> Repo.update!()

    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_with_attachments(%{source_id: source.id})

    File.write!(item.media_filepath, "first artifact")

    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
    {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(4, :days)})

    {Repo.reload(item), watch}
  end
end
