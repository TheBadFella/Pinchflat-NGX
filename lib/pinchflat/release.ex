defmodule Pinchflat.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :pinchflat

  require Logger

  alias Pinchflat.Utils.FilesystemUtils

  @probe_prefix ".pinchflat-perm-probe-"

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Pinchflat.LegacyMigration.pre_migration_check(repo)
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Verifies that the application can write to the directories it actually uses.

  The checks follow the configured paths, so an override such as MEDIA_PATH or
  TMPFILE_PATH is validated instead of a hard-coded default. Each check writes a
  unique probe file and removes it afterwards, leaving existing files untouched.
  """
  def check_file_permissions do
    load_app()
    ensure_yt_dlp_executable!()

    Enum.each(writable_directories(), &check_writable_directory/1)
  end

  defp ensure_yt_dlp_executable! do
    case Application.get_env(:pinchflat, :yt_dlp_executable) do
      path when is_binary(path) and path != "" ->
        :ok

      _ ->
        raise "Pinchflat-ngx cannot find yt-dlp. Put it on PATH or configure :yt_dlp_executable."
    end
  end

  defp writable_directories do
    adapter = Application.get_env(:pinchflat, :database_adapter, :sqlite)

    [
      Application.get_env(:pinchflat, :media_directory),
      Application.get_env(:pinchflat, :metadata_directory),
      Application.get_env(:pinchflat, :extras_directory),
      Application.get_env(:pinchflat, :tmpfile_directory),
      Application.get_env(:tzdata, :data_dir),
      configured_parent(Application.get_env(:pinchflat, :log_path)),
      database_parent(adapter),
      Application.get_env(:pinchflat, :download_staging_directory),
      postgres_backup_directory(adapter),
      configured_parent(Application.get_env(:pinchflat, :yt_dlp_executable))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp configured_parent(path) when is_binary(path) and path != "", do: Path.dirname(path)
  defp configured_parent(_path), do: nil

  defp database_parent(:sqlite) do
    case Application.get_env(:pinchflat, Pinchflat.Repo, []) do
      config when is_list(config) -> config |> Keyword.get(:database) |> configured_parent()
      _ -> nil
    end
  end

  defp database_parent(_adapter), do: nil

  defp postgres_backup_directory(:postgres) do
    Application.get_env(:pinchflat, :postgres_backup_directory)
  end

  defp postgres_backup_directory(_adapter), do: nil

  defp check_writable_directory(directory) do
    Logger.info("Checking permissions for #{directory}")
    probe = Path.join(directory, probe_filename())

    try do
      case FilesystemUtils.write_p(probe, "", [:exclusive]) do
        :ok ->
          Logger.info("Permissions OK")

        {:error, reason} ->
          Logger.error(permission_error_message(directory, reason))
          raise "Pinchflat-ngx cannot write to #{directory} (uid:gid #{current_uid_gid()}): #{inspect(reason)}"
      end
    after
      File.rm(probe)
    end
  end

  defp probe_filename do
    "#{@probe_prefix}#{System.system_time(:microsecond)}-#{:os.getpid()}-#{System.unique_integer([:positive])}"
  end

  defp current_uid_gid do
    try do
      with {uid, 0} <- System.cmd("id", ["-u"]),
           {gid, 0} <- System.cmd("id", ["-g"]) do
        "#{String.trim(uid)}:#{String.trim(gid)}"
      else
        _ -> "unknown"
      end
    rescue
      _ -> "unknown"
    end
  end

  defp permission_error_message(directory, reason) do
    """
    Pinchflat-ngx cannot write to "#{directory}" (probe failed: #{inspect(reason)}).
    The application is running as uid:gid #{current_uid_gid()}.

    Give that identity write access to the host directory mounted at this path.
    If you set `user: "1000:1000"` (or `docker run --user 1000:1000`), the matching
    host directory must be writable by that UID/GID; changing ownership inside the
    image does not change a bind mount. Stop other writers and back up the data
    before changing ownership, and avoid blanket recursive chmod or chown on an
    existing library.

    You can also point the application at another writable location with
    MEDIA_PATH, CONFIG_PATH, METADATA_PATH, EXTRAS_PATH, TMPFILE_PATH, LOG_PATH,
    TZ_DATA_PATH, DATABASE_PATH, DOWNLOAD_STAGING_PATH or POSTGRES_BACKUP_PATH as
    appropriate. Keep the directory containing yt-dlp writable so updates can
    replace it.
    """
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
