defmodule Pinchflat.LegacyMigrationSafetyTest do
  use Pinchflat.DataCase

  alias Pinchflat.LegacyMigration
  alias Pinchflat.Repo

  setup do
    path = Path.join(System.tmp_dir!(), "migration-safety-#{System.unique_integer([:positive])}.json")
    Application.put_env(:pinchflat, :legacy_migration_state_path, path)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :legacy_migration_state_path)
      File.rm(path)
    end)

    %{path: path}
  end

  test "holds the queue which performs source deletion and file sync" do
    assert :local_data in LegacyMigration.mutating_queues()
  end

  test "pending database provenance survives corrupt JSON cache", %{path: path} do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE legacy_migration_records SET provenance='legacy_pinchflat', status='pending_review'"
    )

    File.write!(path, "{broken")
    assert LegacyMigration.legacy_migration_pending?()
  end

  test "pending database provenance survives absent JSON cache" do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE legacy_migration_records SET provenance='legacy_pinchflat', status='pending_review'"
    )

    assert LegacyMigration.legacy_migration_pending?()
  end

  test "completed database provenance is not overridden by a stale pending cache", %{path: path} do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE legacy_migration_records SET provenance='legacy_pinchflat', status='completed'"
    )

    File.write!(path, Jason.encode!(%{provenance: "legacy_pinchflat", status: "pending_review"}))
    refute LegacyMigration.legacy_migration_pending?()
  end

  test "starts every configured queue paused and retains prior choices through restart" do
    Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()
    config = [queues: [local_data: [limit: 1, paused: true], media_fetching: 2, default: 1, future_queue: 1]]
    prepared = LegacyMigration.prepare_oban_config(config)
    assert Enum.all?(prepared[:queues], fn {_queue, options} -> options[:paused] end)
    record = Repo.one!(Pinchflat.LegacyMigration.Record)

    assert record.queue_pauses == %{
             "local_data" => true,
             "media_fetching" => false,
             "default" => false,
             "future_queue" => false
           }

    # A supervisor restart receives paused queue metadata but must not replace the original snapshot.
    LegacyMigration.prepare_oban_config(prepared)
    assert Repo.reload!(record).queue_pauses == record.queue_pauses
    assert {:error, :review_pending} = LegacyMigration.release_mutating_queues!()
    assert :ok = LegacyMigration.complete_review!()
    assert LegacyMigration.get_state().status == "pending_release"
    assert :ok = LegacyMigration.release_mutating_queues!()
    restored = LegacyMigration.prepare_oban_config(config)
    assert restored[:queues][:local_data][:paused]
    assert restored[:queues][:media_fetching] == 2
  end

  test "does not confirm unknown provenance when the durable record is missing" do
    Repo.delete_all(Pinchflat.LegacyMigration.Record)
    assert LegacyMigration.legacy_migration_pending?()
    assert {:error, :unknown_provenance} = LegacyMigration.complete_review!()
  end

  test "queues added on a pending restart get their own pause choice" do
    Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()
    LegacyMigration.prepare_oban_config(queues: [media_fetching: [limit: 1, paused: true]])
    LegacyMigration.prepare_oban_config(queues: [media_fetching: 1, new_queue: 2])
    assert Repo.one!(Pinchflat.LegacyMigration.Record).queue_pauses == %{"media_fetching" => true, "new_queue" => false}
  end

  test "a directory is not counted as verified media" do
    directory = Path.join(System.tmp_dir!(), "review-directory-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rmdir(directory) end)
    item = Pinchflat.MediaFixtures.media_item_fixture(%{media_filepath: directory})
    scan = LegacyMigration.verify_library()
    assert Enum.any?(scan.missing_items, &(&1.id == item.id && &1.error == "not_regular_file"))
  end
end
