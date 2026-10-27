defmodule Pinchflat.MediaWatch.DestructivePreservationTest do
  @moduledoc """
  Gated M2 execution evidence. These tests overwrite and delete a watched
  active original and must not run until the independent M2 safety review
  explicitly approves destructive watched flows.

  Run explicitly after approval:

      mix test --include destructive_watch test/pinchflat/media_watch/destructive_preservation_test.exs
  """

  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media
  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.Repo

  @moduletag :destructive_watch

  setup do
    Application.put_env(:pinchflat, :media_watch_destructive_enabled, true)
    stub(UserScriptRunnerMock, :run, fn _, _ -> {:ok, "", 0} end)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :media_watch_destructive_enabled)
      File.rm_rf(OriginalArchive.root())
    end)

    profile = media_profile_fixture()

    profile =
      profile
      |> Ecto.Changeset.change(watch_window_days: 14)
      |> Repo.update!()

    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_with_attachments(%{source_id: source.id})
    File.write!(item.media_filepath, "first artifact")

    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
    {:ok, item} = Media.update_media_item(item, %{media_downloaded_at: now_minus(1, :day)})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, watch} =
      watch
      |> Ecto.Changeset.change(last_success_at: now, next_check_at: now)
      |> Repo.update()

    %{item: Repo.reload(item), watch: watch}
  end

  test "an approved replacement archives the first bytes before overwriting the active path", %{
    item: item,
    watch: watch
  } do
    item = Repo.preload(item, :metadata)
    first_checksum = :sha256 |> :crypto.hash("first artifact") |> Base.encode16(case: :lower)

    assert {:ok, lease} = MediaWatch.prepare_replacement(item)
    assert Repo.get!(Watch, watch.id).archive_state == "published"

    # This is the mutation the downloader transfer would perform after the
    # guarded commit. The archive must already hold the first bytes.
    File.write!(item.media_filepath, "replacement artifact")

    assert {:ok, manifest} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))

    assert [%{"role" => "media", "sha256" => ^first_checksum}] =
             Enum.filter(manifest["files"], &(&1["role"] == "media"))

    assert :ok = MediaWatch.finish_replacement(lease)
  end

  test "active-file deletion is allowed after archive publication and keeps the archive", %{
    item: item,
    watch: watch
  } do
    item = Repo.preload(item, :metadata)

    assert {:ok, _} = MediaWatch.archive_original(watch, item)
    assert {:ok, _} = Media.delete_media_files(item)

    refute File.exists?(item.media_filepath)
    assert {:ok, _manifest} = MediaWatch.verify_archive(Repo.get!(Watch, watch.id))
  end

  test "deleting the saved original requires the exact confirmation and removes only archive files", %{
    item: item,
    watch: watch
  } do
    item = Repo.preload(item, :metadata)
    assert {:ok, %Watch{original_manifest_path: manifest_path}} = MediaWatch.archive_original(watch, item)
    published = Repo.get!(Watch, watch.id)

    assert {:error, :watch_confirmation_unavailable} =
             OriginalArchive.delete_published(%{
               confirmed: true,
               watch_id: watch.id,
               manifest_path: published.original_manifest_path
             })

    assert {:ok, _} = OriginalArchive.verify_relative(published.original_manifest_path, watch_id: watch.id)
    assert File.exists?(item.media_filepath)
    assert manifest_path == published.original_manifest_path
  end
end
