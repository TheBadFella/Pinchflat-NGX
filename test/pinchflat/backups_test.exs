defmodule Pinchflat.BackupsTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog

  alias Pinchflat.Backups
  alias Pinchflat.Backups.Connection

  describe "connection details" do
    test "maps DATABASE_URL values to pg_dump environment variables without a command-line URL" do
      url = "ecto://backup-user:s3cr3t%21@postgres:5433/pinchflat?sslmode=require"

      assert {:ok, connection} = Connection.from_url(url)
      assert connection.database == "pinchflat"
      assert {"PGHOST", "postgres"} in connection.env
      assert {"PGPORT", "5433"} in connection.env
      assert {"PGUSER", "backup-user"} in connection.env
      assert {"PGPASSWORD", "s3cr3t!"} in connection.env
      assert {"PGDATABASE", "pinchflat"} in connection.env
      assert {"PGSSLMODE", "require"} in connection.env

      args = Pinchflat.Backups.PgDumpRunner.args("/config/extras/backups/file.partial", connection.database)
      refute Enum.any?(args, &String.contains?(&1, "s3cr3t"))
    end

    test "redacts both URI passwords and configured password values" do
      url = "postgresql://user:secret@postgres/pinchflat"
      {:ok, connection} = Connection.from_url(url)

      redacted = Connection.redact("url=#{url} password=secret", connection)

      refute redacted =~ "secret"
      assert redacted =~ "[REDACTED]"
    end
  end

  describe "backup files" do
    setup do
      directory =
        Path.join([
          System.tmp_dir!(),
          "pinchyt-backups-test",
          Integer.to_string(:erlang.unique_integer([:positive]))
        ])

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)
      {:ok, directory: directory}
    end

    test "prunes only generated backup files and retains the newest requested count", %{directory: directory} do
      filenames = [
        "pinchyt-postgres-20260911-120000-000001-0000000000000001.dump",
        "pinchyt-postgres-20260911-120001-000002-0000000000000002.dump",
        "pinchyt-postgres-20260911-120002-000003-0000000000000003.dump"
      ]

      Enum.each(filenames, fn filename -> File.write!(Path.join(directory, filename), "dump") end)
      File.write!(Path.join(directory, "not-a-backup.txt"), "keep")

      assert {:ok, 1} = Backups.prune_backups(directory: directory, retention_count: 2)

      assert Enum.map(Backups.list_backups(directory: directory), & &1.filename) ==
               Enum.take(Enum.reverse(filenames), 2)

      assert File.exists?(Path.join(directory, "not-a-backup.txt"))
    end

    test "retains the newest generated filename when filesystem mtimes tie", %{directory: directory} do
      filenames = [
        "pinchyt-postgres-20260911-120000-000001-0000000000000001.dump",
        "pinchyt-postgres-20260911-120001-000002-0000000000000002.dump",
        "pinchyt-postgres-20260911-120002-000003-0000000000000003.dump"
      ]

      tied_time = {{2026, 9, 11}, {12, 0, 0}}

      Enum.each(filenames, fn filename ->
        path = Path.join(directory, filename)
        File.write!(path, "dump")
        :ok = File.touch(path, tied_time)
      end)

      assert {:ok, 2} = Backups.prune_backups(directory: directory, retention_count: 1)

      assert Enum.map(Backups.list_backups(directory: directory), & &1.filename) == [List.last(filenames)]

      Enum.each(Enum.drop(filenames, -1), fn filename ->
        refute File.exists?(Path.join(directory, filename))
      end)
    end

    test "retains the newer same-second backup before comparing random suffixes", %{directory: directory} do
      older = "pinchyt-postgres-20260911-120000-100000-ffffffffffffffff.dump"
      newer = "pinchyt-postgres-20260911-120000-900000-0000000000000000.dump"
      tied_time = {{2026, 9, 11}, {12, 0, 0}}

      Enum.each([older, newer], fn filename ->
        path = Path.join(directory, filename)
        File.write!(path, "dump")
        :ok = File.touch(path, tied_time)
      end)

      assert {:ok, 1} = Backups.prune_backups(directory: directory, retention_count: 1)
      assert Enum.map(Backups.list_backups(directory: directory), & &1.filename) == [newer]
      refute File.exists?(Path.join(directory, older))
    end

    test "accepts legacy second-precision backup filenames" do
      assert Backups.backup_filename?("pinchyt-postgres-20260911-120000-0000000000000001.dump")
      refute Backups.backup_filename?("pinchyt-postgres-20260911-120000-0000000000000001.dump.partial")
      refute Backups.backup_filename?("../pinchyt-postgres-20260911-120000-0000000000000001.dump")
    end

    test "removes stale partial files but leaves recent partial files", %{directory: directory} do
      stale = Path.join(directory, "pinchyt-postgres-old.dump.partial")
      recent = Path.join(directory, "pinchyt-postgres-recent.dump.partial")
      File.write!(stale, "partial")
      File.write!(recent, "partial")

      old_time = {{2020, 1, 1}, {0, 0, 0}}
      :ok = File.touch(stale, old_time)

      assert :ok =
               Backups.cleanup_partial_files(
                 directory: directory,
                 now: ~U[2026-09-11 00:00:00Z]
               )

      refute File.exists?(stale)
      assert File.exists?(recent)
    end
  end

  describe "SQLite behavior" do
    @describetag :sqlite_only

    test "reports an explicit unavailable state" do
      assert %{available: false, reason: :sqlite, backups: []} = Backups.status()
      assert {:error, :unavailable} = Backups.create_backup()

      assert {:error, :unavailable} =
               Backups.download_path("pinchyt-postgres-20260911-120000-000001-0000000000000001.dump")
    end
  end

  describe "failure logging" do
    @describetag :postgres_only

    setup do
      directory =
        Path.join([
          System.tmp_dir!(),
          "pinchyt-backups-failure-test",
          Integer.to_string(:erlang.unique_integer([:positive]))
        ])

      original_directory = Application.get_env(:pinchflat, :postgres_backup_directory)
      Application.put_env(:pinchflat, :postgres_backup_directory, directory)
      File.mkdir_p!(directory)

      on_exit(fn ->
        Application.put_env(:pinchflat, :postgres_backup_directory, original_directory)
        File.rm_rf!(directory)
      end)

      :ok
    end

    test "cleans a partial file and redacts command output when pg_dump fails" do
      runner = fn _executable, args, _env, _directory ->
        partial_path = args |> Enum.drop_while(&(&1 != "--file")) |> Enum.at(1)
        File.write!(partial_path, "partial dump")
        {"password=postgres", 1}
      end

      log =
        capture_log(fn ->
          assert {:error, :pg_dump_failed} =
                   Backups.create_backup(runner: runner, executable: "pg_dump")
        end)

      assert File.ls!(Backups.backup_directory()) == []
      refute log =~ "password=postgres"
    end

    test "cleans a partial file when the runner exits unexpectedly" do
      runner = fn _executable, args, _env, _directory ->
        partial_path = args |> Enum.drop_while(&(&1 != "--file")) |> Enum.at(1)
        File.write!(partial_path, "cancelled dump")
        raise "cancelled"
      end

      assert_raise RuntimeError, "cancelled", fn ->
        Backups.create_backup(runner: runner, executable: "pg_dump")
      end

      assert File.ls!(Backups.backup_directory()) == []
    end
  end
end
