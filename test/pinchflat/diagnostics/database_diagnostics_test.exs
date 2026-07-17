defmodule Pinchflat.Diagnostics.DatabaseDiagnosticsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Diagnostics.DatabaseDiagnostics
  alias Pinchflat.Diagnostics.DatabaseMaintenanceWorker

  import Pinchflat.MediaFixtures
  import Pinchflat.TasksFixtures

  describe "get_database_stats/0" do
    test "returns file sizes for the database and its sidecars" do
      stats = DatabaseDiagnostics.get_database_stats()

      assert stats.main_file_bytes > 0
      assert stats.total_bytes == stats.main_file_bytes + stats.wal_file_bytes + stats.shm_file_bytes
    end

    test "returns page-level statistics" do
      stats = DatabaseDiagnostics.get_database_stats()

      assert stats.page_size > 0
      assert stats.page_count > 0
      assert stats.reclaimable_bytes == stats.freelist_count * stats.page_size
    end

    test "returns the journal mode" do
      assert DatabaseDiagnostics.get_database_stats().journal_mode in ["wal", "delete", "truncate", "memory"]
    end
  end

  describe "table_row_counts/0" do
    test "returns counts for the tracked tables" do
      counts = Map.new(DatabaseDiagnostics.table_row_counts())

      assert Map.has_key?(counts, "media_items")
      assert Map.has_key?(counts, "sources")
      assert Map.has_key?(counts, "media_profiles")
      assert Map.has_key?(counts, "tasks")
      assert Map.has_key?(counts, "oban_jobs")
    end

    test "counts reflect existing records" do
      media_item_fixture()

      counts = Map.new(DatabaseDiagnostics.table_row_counts())

      assert counts["sources"] == 1
      assert counts["media_items"] == 1
    end
  end

  describe "orphaned_task_count/0" do
    test "returns 0 when all tasks have a job" do
      task_fixture()

      assert DatabaseDiagnostics.orphaned_task_count() == 0
    end
  end

  describe "latest_maintenance_job/0" do
    test "returns nil when no maintenance job has run" do
      assert DatabaseDiagnostics.latest_maintenance_job() == nil
    end

    test "returns the most recent maintenance job" do
      {:ok, job} = DatabaseMaintenanceWorker.kickoff()

      assert DatabaseDiagnostics.latest_maintenance_job().id == job.id
    end
  end

  describe "format_bytes/1" do
    test "formats byte counts in binary units" do
      assert DatabaseDiagnostics.format_bytes(512) == "512 B"
      assert DatabaseDiagnostics.format_bytes(2048) == "2.0 KiB"
      assert DatabaseDiagnostics.format_bytes(5 * 1024 * 1024) == "5.0 MiB"
      assert DatabaseDiagnostics.format_bytes(3 * 1024 * 1024 * 1024) == "3.0 GiB"
    end
  end
end
