defmodule Pinchflat.Diagnostics.DatabasePostgresTest do
  use Pinchflat.DataCase

  @moduletag :postgres_only

  alias Pinchflat.Diagnostics.DatabaseDiagnostics
  alias Pinchflat.Diagnostics.DatabaseMaintenanceWorker

  test "reports PostgreSQL database size" do
    stats = DatabaseDiagnostics.get_database_stats()

    assert stats.adapter == :postgres
    assert stats.total_bytes > 0
    assert stats.journal_mode == nil
  end

  test "does not enqueue SQLite maintenance" do
    assert {:error, :unsupported} = DatabaseMaintenanceWorker.kickoff()
    assert {:error, message} = DatabaseDiagnostics.run_integrity_check(:quick)
    assert message =~ "only available for SQLite"
  end
end
