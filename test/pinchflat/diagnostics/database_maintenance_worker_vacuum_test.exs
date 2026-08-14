defmodule Pinchflat.Diagnostics.DatabaseMaintenanceWorkerVacuumTest do
  # VACUUM can't run inside a transaction, so this test opts out of the SQL
  # sandbox and runs against the test database on a raw connection. The
  # maintenance run doesn't modify any data, so there's nothing to roll back.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Pinchflat.Repo, engine: Oban.Engines.Lite

  import Mox

  alias Pinchflat.Diagnostics.DatabaseDiagnostics
  alias Pinchflat.Diagnostics.DatabaseMaintenanceWorker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pinchflat.Repo, sandbox: false)
    # The connection is automatically checked back in when the test process exits

    stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 1024 * 1024 * 1024 * 1024} end)

    :ok
  end

  test "truncates the WAL and vacuums the database when disk space allows" do
    # Manual args so the run doesn't depend on the opt-in setting's DB state
    assert :ok = perform_job(DatabaseMaintenanceWorker, %{"manual" => true})

    # The final checkpoint must leave the WAL empty — in WAL mode the VACUUM
    # itself inflates the WAL to roughly the size of the database, which would
    # otherwise negate the vacuum's disk savings
    assert DatabaseDiagnostics.get_database_stats().wal_file_bytes == 0
  end
end
