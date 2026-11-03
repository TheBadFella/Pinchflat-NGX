defmodule Pinchflat.Database.MediaSizeMigrationSqliteTest do
  use ExUnit.Case, async: false
  @moduletag :sqlite_only

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  test "SQLite upgrade and rollback preserve existing 64-bit sizes and relationships" do
    migration = Pinchflat.Repo.Migrations.WidenMediaSizeBytes

    unless Code.ensure_loaded?(migration),
      do: Code.require_file("priv/repo/migrations/20261101190000_widen_media_size_bytes.exs")

    directory = Path.join(System.tmp_dir!(), "media-size-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    start_supervised!({FixtureRepo, database: Path.join(directory, "fixture.db")})
    on_exit(fn -> File.rm_rf!(directory) end)
    FixtureRepo.query!("CREATE TABLE media_items (id INTEGER PRIMARY KEY, media_size_bytes INTEGER)")
    FixtureRepo.query!("CREATE TABLE tasks (media_item_id INTEGER REFERENCES media_items(id))")
    FixtureRepo.query!("INSERT INTO media_items VALUES (1, 3650722202), (2, NULL)")
    FixtureRepo.query!("INSERT INTO tasks VALUES (1)")
    version = 20_261_101_190_000

    for direction <- [:up, :down, :up] do
      assert [^version] = Ecto.Migrator.run(FixtureRepo, [{version, migration}], direction, step: 1)
      assert FixtureRepo.query!("SELECT media_size_bytes FROM media_items ORDER BY id").rows == [[3_650_722_202], [nil]]
      assert FixtureRepo.query!("SELECT media_item_id FROM tasks").rows == [[1]]
      assert FixtureRepo.query!("PRAGMA foreign_key_check").rows == []
    end
  end
end
