defmodule Pinchflat.LegacyMigrationProvenanceTest do
  use Pinchflat.DataCase, async: false

  alias Pinchflat.LegacyMigration

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  alias __MODULE__.FixtureRepo, as: Repo

  setup do
    uniq = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "provenance-#{uniq}")
    File.mkdir_p!(dir)
    state_file = Path.join(System.tmp_dir!(), "provenance-state-#{uniq}.json")

    on_exit(fn ->
      Application.delete_env(:pinchflat, :legacy_migration_state_path)
      File.rm(state_file)
      File.rm_rf(dir)
    end)

    start_supervised!({Repo, database: Path.join(dir, "fixture.db"), pool: Ecto.Adapters.SQL.Sandbox})
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Application.put_env(:pinchflat, :legacy_migration_state_path, state_file)

    %{state_file: state_file}
  end

  defp original_schema do
    Ecto.Adapters.SQL.query!(Repo, "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY)")

    Enum.each(1..76, fn version ->
      Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (?)", [version])
    end)

    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (20250317213740)")
    Ecto.Adapters.SQL.query!(Repo, "CREATE TABLE sources (id INTEGER PRIMARY KEY, custom_name TEXT)")
    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO sources VALUES (1, 'Saved original name')")
    Ecto.Adapters.SQL.query!(Repo, "CREATE TABLE settings (id INTEGER PRIMARY KEY, route_token TEXT)")
    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO settings VALUES (1, 'synthetic-installation-token')")
  end

  test "a stale fresh cache cannot skip genuine original review", %{state_file: path} do
    original_schema()
    File.write!(path, Jason.encode!(%{provenance: "fresh_install", status: "completed"}))
    assert LegacyMigration.pre_migration_check(Repo).status == "pending_review"
  end

  test "an original-looking history without sources is not a fresh installation" do
    original_schema()
    Ecto.Adapters.SQL.query!(Repo, "DROP TABLE sources")
    assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
  end

  test "NGX source fields with original-looking history are ambiguous" do
    original_schema()
    Ecto.Adapters.SQL.query!(Repo, "ALTER TABLE sources ADD COLUMN custom_name_locked BOOLEAN")
    assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
  end

  test "fresh empty schema skips welcome" do
    assert %{provenance: "fresh_install", status: "completed"} = LegacyMigration.pre_migration_check(Repo)
  end

  test "application data without migration history is not a fresh installation" do
    original_schema()
    Ecto.Adapters.SQL.query!(Repo, "DROP TABLE schema_migrations")
    assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
  end

  test "application data with empty migration history is not a fresh installation" do
    original_schema()
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM schema_migrations")
    assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
  end

  test "pending original provenance survives partial migration of the same database" do
    original_schema()
    assert LegacyMigration.pre_migration_check(Repo).status == "pending_review"
    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (20260601000000)")
    assert LegacyMigration.pre_migration_check(Repo).status == "pending_review"
  end

  test "pending provenance cannot be transplanted onto a different database" do
    original_schema()
    assert LegacyMigration.pre_migration_check(Repo).status == "pending_review"
    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (20260910160000)")
    Ecto.Adapters.SQL.query!(Repo, "UPDATE settings SET route_token='different-synthetic-installation'")
    assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
  end

  test "a larger unknown migration timestamp is not sufficient NGX provenance" do
    original_schema()
    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (20270101000000)")
    assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
  end

  test "an existing NGX marker with no pending provenance skips welcome" do
    original_schema()
    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (20260910160000)")
    assert %{provenance: "existing_ngx", status: "completed"} = LegacyMigration.pre_migration_check(Repo)
  end
end
