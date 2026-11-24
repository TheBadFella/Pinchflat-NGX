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
      Enum.each(Path.wildcard(state_file <> ".blocked-*"), &File.rm/1)
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

  describe "blocked provenance recovery" do
    @fork_versions [20_260_618_215_000, 20_260_625_174_920, 20_260_629_120_000]

    defp fork_schema do
      original_schema()

      Enum.each(@fork_versions, fn version ->
        Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (?)", [version])
      end)
    end

    defp remove_fork_versions do
      Enum.each(@fork_versions, fn version ->
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = ?", [version])
      end)
    end

    defp read_state_file(path), do: path |> File.read!() |> Jason.decode!()
    defp write_state_file(path, state), do: File.write!(path, Jason.encode!(state, pretty: true))
    defp blocked_backups(path), do: Path.wildcard(path <> ".blocked-*")

    defp discussion_265_block do
      %{
        "error" => "%RuntimeError{message: \"Migration history is not a recognized NGX database\"}",
        "provenance" => "unknown",
        "status" => "blocked"
      }
    end

    test "a fork migration history blocks the first start with a detection failure", %{state_file: path} do
      fork_schema()

      assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end

      state = read_state_file(path)

      assert state["status"] == "blocked"
      assert state["provenance"] == "unknown"
      assert state["block_reason"] == "detection_failed"
      assert is_binary(state["error"])
      assert state["error"] =~ "not a recognized NGX database"
    end

    test "rolling back the fork migrations recovers the previously blocked state", %{state_file: path} do
      fork_schema()
      assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end

      remove_fork_versions()

      assert %{provenance: "legacy_pinchflat", status: "pending_review"} = LegacyMigration.pre_migration_check(Repo)

      # A detection_failed block is reproducible, so it is not backed up.
      assert blocked_backups(path) == []
    end

    test "a restart loop on a still-broken database keeps at most one backup", %{state_file: path} do
      fork_schema()
      write_state_file(path, discussion_265_block())

      for _ <- 1..3 do
        error = assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
        assert Exception.message(error) =~ path
      end

      assert [backup] = blocked_backups(path)
      assert read_state_file(backup) == discussion_265_block()
    end

    test "a hand-written discussion 265 block recovers against a clean legacy database", %{state_file: path} do
      original_schema()
      write_state_file(path, discussion_265_block())

      assert %{provenance: "legacy_pinchflat", status: "pending_review"} = LegacyMigration.pre_migration_check(Repo)

      assert [backup] = blocked_backups(path)
      assert read_state_file(backup) == discussion_265_block()
    end

    test "a discussion 265 block with extra keys stays locked", %{state_file: path} do
      original_schema()

      for extra <- [{"last_scan", %{"status" => "ok"}}, {"original_database_identity", "deadbeef"}] do
        {key, value} = extra
        locked = Map.put(discussion_265_block(), key, value)
        write_state_file(path, locked)

        error = assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
        assert Exception.message(error) =~ "is locked"
        assert Exception.message(error) =~ path

        assert read_state_file(path) == locked
        assert blocked_backups(path) == []
      end
    end

    test "a pending review bound to another database stays locked", %{state_file: path} do
      original_schema()
      assert %{provenance: "legacy_pinchflat", status: "pending_review"} = LegacyMigration.pre_migration_check(Repo)
      pending = read_state_file(path)

      # Database B: a fresh install now lives at the same path.
      Enum.each(["schema_migrations", "sources", "settings"], fn table ->
        Ecto.Adapters.SQL.query!(Repo, "DROP TABLE #{table}")
      end)

      assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
      locked = read_state_file(path)
      assert locked["status"] == "blocked"

      # Database A returns to the path, but the locked block is sticky.
      original_schema()
      assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end

      assert read_state_file(path) == locked
      assert pending["provenance"] == "legacy_pinchflat"
      assert blocked_backups(path) == []
    end

    test "a detection failure on retry backs up the block and rewrites the error", %{state_file: path} do
      fork_schema()
      write_state_file(path, discussion_265_block())
      earlier = read_state_file(path)

      error = assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
      assert Exception.message(error) =~ "not a recognized NGX database"

      assert [backup] = blocked_backups(path)
      assert read_state_file(backup) == earlier

      rewritten = read_state_file(path)
      assert rewritten["status"] == "blocked"
      assert rewritten["provenance"] == "unknown"
      assert rewritten["block_reason"] == "detection_failed"
      assert rewritten["error"] =~ "not a recognized NGX database"
    end

    test "corrupt and unreadable state files raise without being altered", %{state_file: path} do
      original_schema()

      File.write!(path, "{not json")
      error = assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
      assert Exception.message(error) =~ "Cannot read migration provenance from #{path}"
      assert File.read!(path) == "{not json"
      assert blocked_backups(path) == []

      oversized = String.duplicate("0", 1_048_577)
      File.write!(path, oversized)
      assert_raise RuntimeError, fn -> LegacyMigration.pre_migration_check(Repo) end
      assert File.read!(path) == oversized
      assert blocked_backups(path) == []
    end

    test "an existing NGX database recovers from a blocked file", %{state_file: path} do
      original_schema()
      Ecto.Adapters.SQL.query!(Repo, "INSERT INTO schema_migrations VALUES (20260910160000)")
      write_state_file(path, discussion_265_block())

      assert %{provenance: "existing_ngx", status: "completed"} = LegacyMigration.pre_migration_check(Repo)

      assert [backup] = blocked_backups(path)
      assert read_state_file(backup) == discussion_265_block()
    end
  end
end
