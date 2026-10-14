defmodule Pinchflat.LegacyMigrationScanTest do
  use Pinchflat.DataCase
  import Pinchflat.MediaFixtures
  alias Pinchflat.LegacyMigration

  setup do
    path = Path.join(System.tmp_dir!(), "scan-#{System.unique_integer([:positive])}.json")
    Application.put_env(:pinchflat, :legacy_migration_state_path, path)
    Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

    on_exit(fn ->
      for pid <- Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor),
          do: Task.Supervisor.terminate_child(Pinchflat.LegacyMigration.ScanSupervisor, pid)

      Application.delete_env(:pinchflat, :legacy_migration_state_path)
      File.rm(path)
    end)

    %{path: path}
  end

  test "first request schedules a supervised scan and incomplete approval stays held" do
    media_item_fixture(%{media_filepath: "/missing/scheduled", media_size_bytes: 10})
    assert %{status: :running, complete: false} = LegacyMigration.get_or_run_verification()
    assert LegacyMigration.legacy_migration_pending?()

    for pid <- Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
    end

    assert %{status: :issues_detected, complete: true, processed_count: 1} = LegacyMigration.get_or_run_verification()
  end

  test "an interrupted scan cannot appear completed", %{path: path} do
    summary = LegacyMigration.verify_library()

    File.write!(
      path,
      Jason.encode!(%{
        provenance: "legacy_pinchflat",
        status: "pending_review",
        last_scan: Map.put(summary, :status, :running)
      })
    )

    assert LegacyMigration.get_or_run_verification().status == :interrupted
    assert LegacyMigration.legacy_migration_pending?()
  end

  test "incomplete cached summary is reported as a scan error", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{provenance: "legacy_pinchflat", status: "pending_review", last_scan: %{status: "ok"}})
    )

    assert LegacyMigration.get_or_run_verification().status == :error
  end

  for {name, change} <- [
        {"invalid completion flag", %{complete: "false"}},
        {"invalid status", %{status: %{status: "ok"}}},
        {"invalid item sample", %{missing_items: [123]}},
        {"inconsistent completed counts", %{db_downloaded_count: 999}}
      ] do
    test "damaged cache: #{name}", %{path: path} do
      summary = LegacyMigration.verify_library() |> Map.merge(unquote(Macro.escape(change)))
      File.write!(path, Jason.encode!(%{provenance: "legacy_pinchflat", status: "pending_review", last_scan: summary}))
      assert LegacyMigration.get_or_run_verification().status == :error
      assert LegacyMigration.legacy_migration_pending?()
    end
  end

  test "a completed scan from a prior startup cannot certify current files", %{path: path} do
    media_path = path <> ".mp4"
    File.write!(media_path, "fixture")
    media_item_fixture(%{media_filepath: media_path, media_size_bytes: 7})
    summary = LegacyMigration.verify_library()
    assert summary.verified_count == 1
    File.rm!(media_path)
    summary = Map.delete(summary, :scan_session)
    File.write!(path, Jason.encode!(%{provenance: "legacy_pinchflat", status: "pending_review", last_scan: summary}))
    assert %{status: :running, complete: false} = LegacyMigration.get_or_run_verification()

    for pid <- Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
    end

    assert %{missing_count: 1, verified_count: 0, complete: true} = LegacyMigration.get_or_run_verification()
  end

  test "scans keep a bounded sample while counting every inaccessible item" do
    for n <- 1..25, do: media_item_fixture(%{media_filepath: "/missing/scan-#{n}", media_size_bytes: 10})
    summary = LegacyMigration.verify_library()
    assert summary.missing_count == 25
    assert length(summary.missing_items) == 20
    assert summary.processed_count == 25
    assert summary.complete
  end

  test "mount directories and zero media are not proof of a complete readable scan" do
    previous = Application.get_env(:pinchflat, :media_directory)
    Application.put_env(:pinchflat, :media_directory, "/missing/scan-mount")
    on_exit(fn -> Application.put_env(:pinchflat, :media_directory, previous) end)
    summary = LegacyMigration.verify_library()
    assert summary.status == :issues_detected
    refute summary.mounts.media_accessible
    assert summary.complete
  end

  test "a database read error leaves an incomplete error result" do
    Ecto.Adapters.SQL.query!(Pinchflat.Repo, "ALTER TABLE media_items RENAME TO scan_hidden_media_items")

    try do
      summary = LegacyMigration.verify_library()
      assert summary.status == :error
      refute summary.complete
      assert LegacyMigration.legacy_migration_pending?()
    after
      Ecto.Adapters.SQL.query!(Pinchflat.Repo, "ALTER TABLE scan_hidden_media_items RENAME TO media_items")
    end
  end
end
