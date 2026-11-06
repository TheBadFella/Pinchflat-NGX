defmodule Pinchflat.Database.TaskProgressBytesMigrationSqliteTest do
  use ExUnit.Case, async: false
  @moduletag :sqlite_only

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  test "SQLite upgrade and rollback preserve existing 64-bit byte counters and relationships" do
    migration = Pinchflat.Repo.Migrations.WidenTaskProgressBytes

    unless Code.ensure_loaded?(migration),
      do: Code.require_file("priv/repo/migrations/20261106020000_widen_task_progress_bytes.exs")

    directory = Path.join(System.tmp_dir!(), "task-bytes-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    start_supervised!({FixtureRepo, database: Path.join(directory, "fixture.db")})
    on_exit(fn -> File.rm_rf!(directory) end)

    FixtureRepo.query!(
      "CREATE TABLE tasks (id INTEGER PRIMARY KEY, progress_downloaded_bytes INTEGER, progress_total_bytes INTEGER)"
    )

    FixtureRepo.query!("INSERT INTO tasks VALUES (1, 5998903849, 5998903849), (2, NULL, NULL)")
    version = 20_261_106_020_000

    for direction <- [:up, :down, :up] do
      assert [^version] = Ecto.Migrator.run(FixtureRepo, [{version, migration}], direction, step: 1)

      assert FixtureRepo.query!("SELECT progress_downloaded_bytes, progress_total_bytes FROM tasks ORDER BY id").rows ==
               [
                 [5_998_903_849, 5_998_903_849],
                 [nil, nil]
               ]

      assert FixtureRepo.query!("PRAGMA foreign_key_check").rows == []
    end
  end
end
