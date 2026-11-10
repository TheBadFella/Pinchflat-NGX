defmodule Pinchflat.ReleasePermissionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pinchflat.Release

  @env_keys [
    :media_directory,
    :metadata_directory,
    :extras_directory,
    :tmpfile_directory,
    :download_staging_directory,
    :postgres_backup_directory,
    :log_path,
    :yt_dlp_executable,
    :database_adapter
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "release-perms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Map.new(@env_keys, &{&1, Application.get_env(:pinchflat, &1)})
    previous_repo = Application.get_env(:pinchflat, Pinchflat.Repo)
    previous_tzdata = Application.get_env(:tzdata, :data_dir)

    Application.put_env(:pinchflat, :media_directory, Path.join(root, "media"))
    Application.put_env(:pinchflat, :metadata_directory, Path.join(root, "metadata"))
    Application.put_env(:pinchflat, :extras_directory, Path.join(root, "extras"))
    Application.put_env(:pinchflat, :tmpfile_directory, Path.join(root, "tmp"))
    Application.put_env(:pinchflat, :download_staging_directory, Path.join(root, "staging"))
    Application.put_env(:pinchflat, :postgres_backup_directory, nil)
    Application.put_env(:pinchflat, :log_path, Path.join([root, "logs", "pinchflat.log"]))
    Application.put_env(:pinchflat, :yt_dlp_executable, Path.join([root, "runtime", "bin", "yt-dlp"]))
    Application.put_env(:pinchflat, :database_adapter, :sqlite)
    Application.put_env(:pinchflat, Pinchflat.Repo, database: Path.join([root, "db", "pinchflat.db"]))
    Application.put_env(:tzdata, :data_dir, Path.join(root, "tzdata"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_app_env(:pinchflat, key, value) end)
      restore_app_env(:pinchflat, Pinchflat.Repo, previous_repo)
      restore_app_env(:tzdata, :data_dir, previous_tzdata)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "creates and verifies every configured writable directory", %{root: root} do
    assert :ok = Release.check_file_permissions()

    for directory <- ~w(media metadata extras tmp tzdata staging logs db runtime/bin) do
      assert File.dir?(Path.join(root, directory)), "expected #{directory} to be writable"
    end
  end

  test "uses unique probes and leaves existing files untouched" do
    media = Application.get_env(:pinchflat, :media_directory)
    File.mkdir_p!(media)
    keep = Path.join(media, ".keep")
    File.write!(keep, "keep me")

    assert :ok = Release.check_file_permissions()

    assert File.read!(keep) == "keep me"
    assert Path.wildcard(Path.join(media, ".pinchflat-perm-probe-*")) == []
  end

  test "checks the PostgreSQL backup directory for the postgres adapter", %{root: root} do
    backup = Path.join(root, "postgres-backups")
    Application.put_env(:pinchflat, :database_adapter, :postgres)
    Application.put_env(:pinchflat, :postgres_backup_directory, backup)

    assert :ok = Release.check_file_permissions()
    assert File.dir?(backup)
  end

  test "raises an actionable error when a configured path is not writable", %{root: root} do
    blocker = Path.join(root, "blocker")
    File.write!(blocker, "")
    Application.put_env(:pinchflat, :media_directory, Path.join(blocker, "media"))

    previous_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/cannot write to/, fn ->
          Release.check_file_permissions()
        end
      end)

    assert log =~ blocker
    assert log =~ "uid:gid"
    assert log =~ ~s(user: "1000:1000")
  end

  test "fails clearly when yt-dlp cannot be resolved" do
    Application.put_env(:pinchflat, :yt_dlp_executable, nil)

    assert_raise RuntimeError, ~r/cannot find yt-dlp/, fn ->
      Release.check_file_permissions()
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
