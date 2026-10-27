defmodule Pinchflat.Database.SqliteSnapshot do
  @moduledoc "Reads a retained SQLite library without opening it for writes."
  alias Exqlite.Sqlite3

  @tables ~w(media_profiles settings_backup settings sources media_items source_metadata media_metadata channel_discovery_suggestions reconcile_plans reconcile_plan_items share_tokens oban_jobs tasks legacy_migration_records media_watches media_watch_events)
  @migration_version 20_261_007_120_000

  def tables, do: @tables

  def with_database(path, fun) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, db} ->
        try do
          :ok = Sqlite3.set_busy_timeout(db, 30_000)
          fun.(db)
        after
          Sqlite3.close(db)
        end

      _ ->
        {:error, :source_unavailable}
    end
  end

  def validate!(db) do
    if query!(db, "PRAGMA integrity_check") != [["ok"]], do: fail(:source_integrity)
    if query!(db, "PRAGMA foreign_key_check") != [], do: fail(:source_foreign_keys)
    tables = query!(db, "SELECT name FROM sqlite_master WHERE type = 'table'") |> List.flatten()

    unknown =
      Enum.reject(
        tables,
        &(&1 in (@tables ++
                   ~w(schema_migrations sqlite_sequence sqlite_stat1 sqlite_stat4 sqlean_define postgres_migration_records)) or
            &1 in ~w(media_items_search_index media_items_search_index_config media_items_search_index_content media_items_search_index_data media_items_search_index_docsize media_items_search_index_idx))
      )

    if unknown != [], do: fail(:unsupported_source_tables)

    expected =
      Application.app_dir(:pinchflat, "priv/repo/migrations")
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&(Path.basename(&1) |> String.split("_") |> hd() |> String.to_integer()))
      |> Enum.reject(&(&1 == @migration_version))
      |> Enum.sort()

    versions =
      query!(db, "SELECT version FROM schema_migrations")
      |> List.flatten()
      |> Enum.reject(&(&1 == @migration_version))
      |> Enum.sort()

    if versions != expected, do: fail(:unsupported_source_version)
    if query!(db, "SELECT COUNT(*) FROM settings") != [[1]], do: fail(:source_settings)

    if query!(db, "SELECT COUNT(*) FROM legacy_migration_records WHERE status != 'completed' OR status IS NULL") != [
         [0]
       ],
       do: fail(:legacy_review_pending)

    :ok
  end

  def backup!(db, directory) do
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    [[pages]] = query!(db, "PRAGMA page_count")
    [[page_size]] = query!(db, "PRAGMA page_size")

    case Pinchflat.Diagnostics.DiskSpaceChecker.available_bytes(directory) do
      {:ok, available} when available >= pages * page_size + 10_000_000 -> :ok
      _ -> fail(:backup_space_unavailable)
    end

    path = Path.join(directory, "sqlite-before-postgres-#{Ecto.UUID.generate()}.db")
    query!(db, "VACUUM INTO ?", [path])
    File.chmod!(path, 0o600)
    path
  end

  def query!(db, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, params)

      case Sqlite3.fetch_all(db, statement) do
        {:ok, rows} -> rows
        {:error, _} -> fail(:source_read_failed)
      end
    after
      Sqlite3.release(db, statement)
    end
  end

  def fold!(db, sql, initial, fun) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      fold_chunks!(db, statement, initial, fun)
    after
      Sqlite3.release(db, statement)
    end
  end

  defp fold_chunks!(db, statement, acc, fun) do
    case Sqlite3.multi_step(db, statement, 500) do
      {:rows, rows} -> fold_chunks!(db, statement, fun.(rows, acc), fun)
      {:done, rows} -> fun.(rows, acc)
      {:error, _} -> fail(:source_read_failed)
    end
  end

  def fail(reason), do: throw({:migration_error, reason})
end
