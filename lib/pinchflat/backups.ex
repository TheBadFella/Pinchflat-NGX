defmodule Pinchflat.Backups do
  @moduledoc """
  PostgreSQL database backup management.

  Backups are custom-format `pg_dump` files stored under the persistent
  configuration directory. SQLite builds expose an explicit unavailable state
  and never attempt to invoke PostgreSQL tooling.
  """

  require Logger

  alias Pinchflat.Backups.Connection
  alias Pinchflat.Backups.PgDumpRunner
  alias Pinchflat.Database
  alias Pinchflat.Settings

  @default_retention_count 7
  @partial_stale_after_seconds 60 * 60
  @backup_prefix "pinchyt-postgres-"
  @backup_extension ".dump"
  @partial_extension ".partial"
  @filename_pattern ~r/\Apinchyt-postgres-(\d{8})-(\d{6})-(\d{6})-([a-f0-9]{16})\.dump\z/
  @legacy_filename_pattern ~r/\Apinchyt-postgres-(\d{8})-(\d{6})-([a-f0-9]{16})\.dump\z/

  @type backup :: %{
          filename: String.t(),
          modified_at: DateTime.t(),
          path: String.t(),
          size: non_neg_integer()
        }

  @doc "Returns the PostgreSQL backup capability and current retained files."
  @spec status() :: map()
  def status do
    if Database.postgres?() do
      %{
        available: true,
        backups: list_backups(),
        retention_count: retention_count()
      }
    else
      %{available: false, backups: [], reason: :sqlite}
    end
  end

  @doc "Returns true when this build can create PostgreSQL backups."
  @spec available?() :: boolean()
  def available?, do: Database.postgres?()

  @doc "Returns the persistent directory used for successful backup files."
  @spec backup_directory() :: String.t()
  def backup_directory do
    Application.get_env(:pinchflat, :postgres_backup_directory) ||
      Path.join(Application.fetch_env!(:pinchflat, :extras_directory), "backups")
  end

  @doc "Returns successful backups ordered newest first."
  @spec list_backups(keyword()) :: [backup()]
  def list_backups(opts \\ []) do
    directory = Keyword.get(opts, :directory, backup_directory())

    case File.ls(directory) do
      {:ok, filenames} ->
        filenames
        |> Enum.filter(&backup_filename?/1)
        |> Enum.map(&backup_metadata(directory, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(&newer_backup?/2)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Unable to list PostgreSQL backups: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Creates one PostgreSQL custom-format backup and prunes older successful
  backups according to the configured retention count.

  A `runner` option is accepted for focused tests; production callers use the
  cancellation-aware `PgDumpRunner` implementation.
  """
  @spec create_backup(keyword()) :: {:ok, backup()} | {:error, atom()}
  def create_backup(opts \\ []) do
    if available?() do
      :global.trans({__MODULE__, :create_backup}, fn -> do_create_backup(opts) end)
    else
      {:error, :unavailable}
    end
  end

  @doc "Returns a validated path for an authorized backup download."
  @spec download_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def download_path(filename) when is_binary(filename) do
    if available?() and backup_filename?(filename) do
      path = Path.join(backup_directory(), filename)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> {:ok, path}
        {:ok, _stat} -> {:error, :not_found}
        {:error, _reason} -> {:error, :not_found}
      end
    else
      if available?(), do: {:error, :invalid_filename}, else: {:error, :unavailable}
    end
  end

  def download_path(_filename), do: if(available?(), do: {:error, :invalid_filename}, else: {:error, :unavailable})

  @doc "Prunes a directory to the requested number of successful backups."
  @spec prune_backups(keyword()) :: {:ok, non_neg_integer()}
  def prune_backups(opts \\ []) do
    directory = Keyword.get(opts, :directory, backup_directory())
    keep = Keyword.get(opts, :retention_count, retention_count())
    backups = list_backups(directory: directory)

    backups
    |> Enum.drop(keep)
    |> Enum.reduce_while(0, fn backup, removed ->
      case File.rm(backup.path) do
        :ok ->
          {:cont, removed + 1}

        {:error, :enoent} ->
          {:cont, removed}

        {:error, reason} ->
          Logger.warning("Unable to prune PostgreSQL backup #{backup.filename}: #{inspect(reason)}")
          {:halt, removed}
      end
    end)
    |> then(&{:ok, &1})
  end

  @doc "Removes partial files older than the safety grace period."
  @spec cleanup_partial_files(keyword()) :: :ok
  def cleanup_partial_files(opts \\ []) do
    directory = Keyword.get(opts, :directory, backup_directory())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, filenames} <- File.ls(directory) do
      Enum.each(filenames, fn filename ->
        if String.starts_with?(filename, @backup_prefix) and String.ends_with?(filename, @partial_extension) do
          path = Path.join(directory, filename)

          with {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.lstat(path),
               {:ok, modified_at} <- datetime_from_erl(mtime),
               true <- DateTime.diff(now, modified_at, :second) >= @partial_stale_after_seconds do
            _ = File.rm(path)
          end
        end
      end)
    end

    :ok
  end

  @doc "Returns the configured number of successful backups to retain."
  @spec retention_count() :: pos_integer()
  def retention_count do
    case Settings.get(:postgres_backup_retention_count) do
      {:ok, count} when is_integer(count) and count > 0 -> count
      _ -> @default_retention_count
    end
  end

  @doc false
  def backup_filename?(filename) when is_binary(filename) do
    Regex.match?(@filename_pattern, filename) or Regex.match?(@legacy_filename_pattern, filename)
  end

  def backup_filename?(_filename), do: false

  defp do_create_backup(opts) do
    directory = backup_directory()
    :ok = File.mkdir_p(directory)
    cleanup_partial_files(directory: directory)

    with {:ok, connection} <- Connection.configured(),
         {:ok, executable} <- executable(opts),
         {:ok, retention} <- requested_retention(opts) do
      filename = backup_filename()
      final_path = Path.join(directory, filename)
      partial_path = final_path <> @partial_extension
      runner = Keyword.get(opts, :runner, &PgDumpRunner.run/4)
      args = PgDumpRunner.args(partial_path, connection.database)

      try do
        {output, status} = runner.(executable, args, connection.env, directory)

        cond do
          status != 0 ->
            log_failure(status, output, connection)
            {:error, :pg_dump_failed}

          not valid_dump_file?(partial_path) ->
            Logger.error("PostgreSQL backup completed without producing a usable dump")
            {:error, :empty_backup}

          true ->
            case File.rename(partial_path, final_path) do
              :ok ->
                case backup_metadata(final_path) do
                  nil ->
                    Logger.error("Finalized PostgreSQL backup could not be inspected")
                    {:error, :finalize_failed}

                  backup ->
                    _ = prune_backups(directory: directory, retention_count: retention)
                    {:ok, backup}
                end

              {:error, reason} ->
                Logger.error("Unable to finalize PostgreSQL backup: #{inspect(reason)}")
                {:error, :finalize_failed}
            end
        end
      after
        _ = File.rm(partial_path)
      end
    else
      {:error, reason} ->
        Logger.error("PostgreSQL backup unavailable: #{backup_error_message(reason)}")
        {:error, reason}
    end
  end

  defp executable(opts) do
    case Keyword.get(opts, :executable, PgDumpRunner.executable()) do
      executable when is_binary(executable) and executable != "" -> {:ok, executable}
      _ -> {:error, :pg_dump_unavailable}
    end
  end

  defp requested_retention(opts) do
    retention = Keyword.get(opts, :retention_count, retention_count())

    if is_integer(retention) and retention > 0 do
      {:ok, retention}
    else
      {:error, :invalid_retention}
    end
  end

  defp backup_filename do
    timestamp = DateTime.utc_now()
    calendar_timestamp = Calendar.strftime(timestamp, "%Y%m%d-%H%M%S")
    {microseconds, _precision} = timestamp.microsecond
    microsecond_timestamp = microseconds |> Integer.to_string() |> String.pad_leading(6, "0")
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    @backup_prefix <> calendar_timestamp <> "-" <> microsecond_timestamp <> "-" <> suffix <> @backup_extension
  end

  defp valid_dump_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp backup_metadata(directory, filename) do
    backup_metadata(Path.join(directory, filename))
  end

  defp backup_metadata(path) do
    with {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <- File.lstat(path),
         {:ok, modified_at} <- datetime_from_erl(mtime) do
      %{
        filename: Path.basename(path),
        modified_at: modified_at,
        path: path,
        size: size
      }
    else
      _ -> nil
    end
  end

  defp newer_backup?(left, right) do
    case DateTime.compare(left.modified_at, right.modified_at) do
      :gt -> true
      :lt -> false
      :eq -> filename_order_key(left.filename) > filename_order_key(right.filename)
    end
  end

  defp filename_order_key(filename) do
    case Regex.run(@filename_pattern, filename, capture: :all_but_first) do
      [date, time, microseconds, suffix] -> {date <> time <> microseconds, suffix, 1}
      _ -> legacy_filename_order_key(filename)
    end
  end

  defp legacy_filename_order_key(filename) do
    case Regex.run(@legacy_filename_pattern, filename, capture: :all_but_first) do
      [date, time, suffix] -> {date <> time <> "000000", suffix, 0}
      _ -> {"", "", -1}
    end
  end

  defp datetime_from_erl({date, time}) do
    NaiveDateTime.from_erl({date, time})
    |> case do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      error -> error
    end
  end

  defp log_failure(status, output, connection) do
    safe_output = output |> to_string() |> Connection.redact(connection) |> String.slice(0, 1_000)
    Logger.error("PostgreSQL backup failed with status #{status}: #{safe_output}")
  end

  defp backup_error_message(:database_url_missing), do: "DATABASE_URL is not configured"
  defp backup_error_message(:pg_dump_unavailable), do: "pg_dump is not installed"
  defp backup_error_message(:unsupported_database_url), do: "DATABASE_URL is not a PostgreSQL URL"
  defp backup_error_message(:database_name_missing), do: "DATABASE_URL does not contain a database name"
  defp backup_error_message(reason), do: inspect(reason)
end
