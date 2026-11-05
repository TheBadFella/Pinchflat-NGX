defmodule Pinchflat.Database.SqliteSnapshotTest do
  use Pinchflat.DataCase

  alias Pinchflat.Database.SqliteSnapshot

  @tag :sqlite_only
  test "the transfer validator accepts the schema created by the actual SQLite migrations" do
    database = Application.fetch_env!(:pinchflat, Pinchflat.Repo)[:database]

    assert :ok =
             SqliteSnapshot.with_database(database, fn db ->
               assert [["share_tokens"]] =
                        SqliteSnapshot.query!(db, "SELECT name FROM sqlite_master WHERE name='share_tokens'")

               SqliteSnapshot.validate!(db)
             end)
  end

  test "retries prune migration snapshots while retaining other backups and the source" do
    directory = Path.join(System.tmp_dir!(), "snapshot-retention-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    source = Path.join(directory, "sqlite-before-postgres-source.db")
    unrelated = Path.join(directory, "pinchflat.db.backup-retained")
    File.write!(unrelated, "retained")
    {:ok, db} = Exqlite.Sqlite3.open(source)

    try do
      :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE fixture (id INTEGER PRIMARY KEY); INSERT INTO fixture VALUES (1)")
    after
      Exqlite.Sqlite3.close(db)
    end

    before = File.read!(source)

    SqliteSnapshot.with_database(source, fn db ->
      SqliteSnapshot.query!(db, "CREATE TEMP TABLE snapshot_check (id INTEGER)")
      first = SqliteSnapshot.backup!(db, directory)
      second = SqliteSnapshot.backup!(db, directory)
      refute File.exists?(first)
      assert File.regular?(second)

      assert Enum.sort(Path.wildcard(Path.join(directory, "sqlite-before-postgres-*.db"))) ==
               Enum.sort([source, second])

      assert File.read!(unrelated) == "retained"
      assert File.read!(source) == before
      assert [[1]] == SqliteSnapshot.with_database(second, &SqliteSnapshot.query!(&1, "SELECT id FROM fixture"))
    end)
  end
end
