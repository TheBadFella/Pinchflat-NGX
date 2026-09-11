defmodule Pinchflat.Backups.PostgresIntegrationTest do
  use Pinchflat.DataCase

  @moduletag :postgres_only

  alias Pinchflat.Backups

  setup do
    directory =
      Path.join([
        System.tmp_dir!(),
        "pinchyt-postgres-backups",
        Integer.to_string(:erlang.unique_integer([:positive]))
      ])

    original_directory = Application.get_env(:pinchflat, :postgres_backup_directory)
    Application.put_env(:pinchflat, :postgres_backup_directory, directory)
    File.mkdir_p!(directory)

    on_exit(fn ->
      Application.put_env(:pinchflat, :postgres_backup_directory, original_directory)
      File.rm_rf!(directory)
    end)

    {:ok, directory: directory}
  end

  test "pg_dump creates a restorable custom-format backup", %{directory: directory} do
    assert {:ok, %{filename: filename, path: path, size: size}} = Backups.create_backup()
    assert Backups.backup_filename?(filename)
    assert size > 0
    assert File.exists?(path)
    assert Path.dirname(path) == directory

    {output, status} = System.cmd("pg_restore", ["--list", path], stderr_to_stdout: true)

    assert status == 0
    assert output =~ "TABLE"
  end

  test "cleans failed pg_dump output and redacts credentials from logs", %{directory: directory} do
    runner = fn _executable, args, _env, _working_directory ->
      partial_path = args |> Enum.drop_while(&(&1 != "--file")) |> Enum.at(1)
      File.write!(partial_path, "incomplete")
      {"connection password postgres should never be logged", 1}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :pg_dump_failed} =
                 Backups.create_backup(runner: runner, executable: "pg_dump")
      end)

    assert File.ls!(directory) == []
    refute log =~ "connection password postgres"
    refute log =~ "ecto://postgres:postgres"
  end
end
