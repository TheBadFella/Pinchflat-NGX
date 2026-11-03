defmodule Pinchflat.Database.WatchPolicyMigrationSqliteTest do
  use ExUnit.Case, async: false
  @moduletag :sqlite_only

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  @migration {20_261_025_120_000, Pinchflat.Repo.Migrations.AddWatchWindowDaysToProfilesAndSources}

  setup do
    unless Code.ensure_loaded?(Pinchflat.Repo.Migrations.AddWatchWindowDaysToProfilesAndSources) do
      Code.require_file("priv/repo/migrations/20261025120000_add_watch_window_days_to_profiles_and_sources.exs")
    end

    directory = Path.join(System.tmp_dir!(), "watch-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    start_supervised!({FixtureRepo, database: Path.join(directory, "fixture.db")})
    on_exit(fn -> File.rm_rf!(directory) end)
    FixtureRepo.query!("CREATE TABLE media_profiles (id INTEGER PRIMARY KEY, name TEXT)")
    FixtureRepo.query!("CREATE TABLE sources (id INTEGER PRIMARY KEY, custom_name TEXT)")
    FixtureRepo.query!("INSERT INTO media_profiles (id, name) VALUES (1, 'keep')")
    FixtureRepo.query!("INSERT INTO sources (id, custom_name) VALUES (1, 'keep')")
    :ok
  end

  test "populated SQLite policy migration refuses an unsafe rollback without changing schema or version" do
    assert [20_261_025_120_000] = Ecto.Migrator.run(FixtureRepo, [@migration], :up, step: 1)
    assert FixtureRepo.query!("SELECT watch_window_days FROM media_profiles WHERE id=1").rows == [[0]]
    assert FixtureRepo.query!("SELECT watch_window_days FROM sources WHERE id=1").rows == [[nil]]
    assert {:error, _} = FixtureRepo.query("UPDATE media_profiles SET watch_window_days=366 WHERE id=1")
    assert {:error, _} = FixtureRepo.query("UPDATE sources SET watch_window_days=-1 WHERE id=1")

    assert_raise RuntimeError, ~r/refusing to mark a partial rollback successful/, fn ->
      Ecto.Migrator.run(FixtureRepo, [@migration], :down, step: 1)
    end

    assert 20_261_025_120_000 in Ecto.Migrator.migrated_versions(FixtureRepo)
    assert FixtureRepo.query!("SELECT name, watch_window_days FROM media_profiles WHERE id=1").rows == [["keep", 0]]
    assert FixtureRepo.query!("SELECT custom_name, watch_window_days FROM sources WHERE id=1").rows == [["keep", nil]]
    assert [] = Ecto.Migrator.run(FixtureRepo, [@migration], :up, step: 1)
  end
end
