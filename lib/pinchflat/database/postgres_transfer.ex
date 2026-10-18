defmodule Pinchflat.Database.PostgresTransfer do
  @moduledoc "One explicit, transactional transfer from a retained SQLite snapshot."
  alias Pinchflat.Database.SqliteSnapshot, as: Snapshot
  alias Pinchflat.Repo
  import Ecto.Query, only: [from: 2]

  def run(source, backup_directory) do
    Repo.transaction(
      fn ->
        if Repo.query!("SELECT pg_try_advisory_xact_lock(870071)").rows != [[true]], do: Repo.rollback(:migration_busy)

        result =
          Snapshot.with_database(source, fn db ->
            Snapshot.validate!(db)
            backup = Snapshot.backup!(db, backup_directory)

            Snapshot.with_database(backup, fn snapshot ->
              Snapshot.validate!(snapshot)
              transfer!(snapshot, backup)
            end)
          end)

        case result do
          {:error, reason} -> Repo.rollback(reason)
          report -> report
        end
      end,
      timeout: :infinity
    )
  rescue
    _error -> {:error, :transfer_failed}
  catch
    {:migration_error, reason} -> {:error, reason}
  end

  defp transfer!(db, backup) do
    tables = Snapshot.tables()
    Repo.query!("LOCK TABLE " <> Enum.join(tables, ", ") <> " IN ACCESS EXCLUSIVE MODE")

    Enum.each(tables -- ["settings", "settings_backup", "legacy_migration_records"], fn table ->
      if Repo.query!("SELECT COUNT(*) FROM " <> table).rows != [[0]], do: Repo.rollback(:target_not_empty)
    end)

    if Repo.query!(
         "SELECT COUNT(*) FROM legacy_migration_records WHERE provenance NOT IN ('fresh_install', 'existing_or_fresh') OR status != 'completed' OR provenance IS NULL OR status IS NULL OR original_max_version IS NOT NULL OR original_source_count IS NOT NULL OR confirmed_at IS NOT NULL OR queue_pauses IS NOT NULL OR artwork_repairs IS NOT NULL"
       ).rows != [[0]],
       do: Repo.rollback(:target_not_empty)

    record = Repo.one!(from(r in Pinchflat.Database.PostgresMigrationRecord, where: r.id == 1, lock: "FOR UPDATE"))
    if record.status != "running", do: Repo.rollback(:not_running)
    # The fresh schema seeds settings and its obsolete pre-2024 backup. The
    # explicit transfer replaces these two rows with the retained library's values.
    Enum.each(["settings", "settings_backup", "legacy_migration_records"], &Repo.query!("DELETE FROM " <> &1))
    results = Map.new(tables, fn table -> {table, copy_table!(db, table)} end)
    report = %{"backup" => backup, "tables" => results, "library" => library_summary()}
    record = Repo.get!(Pinchflat.Database.PostgresMigrationRecord, 1)
    record |> Ecto.Changeset.change(status: "pending_review", report: report) |> Repo.update!()
    report
  end

  defp library_summary do
    [[downloaded, bytes]] =
      Repo.query!(
        "SELECT COUNT(*), COALESCE(SUM(media_size_bytes), 0) FROM media_items WHERE media_downloaded_at IS NOT NULL"
      ).rows

    missing =
      Repo.stream(
        from(mi in Pinchflat.Media.MediaItem, where: not is_nil(mi.media_filepath), select: mi.media_filepath)
      )
      |> Enum.count(&(not File.regular?(&1)))

    %{"downloaded_items" => downloaded, "recorded_bytes" => bytes, "missing_media_files" => missing}
  end

  defp copy_table!(db, table) do
    columns =
      Repo.query!(
        "SELECT column_name, udt_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position",
        [table]
      ).rows
      |> Enum.reject(&(hd(&1) == "search_vector"))

    source_columns = Snapshot.query!(db, "PRAGMA table_info(" <> table <> ")") |> Enum.map(&Enum.at(&1, 1))
    names = Enum.map(columns, &hd/1)
    if Enum.sort(source_columns) != Enum.sort(names), do: Repo.rollback(:unsupported_source_columns)
    select = Enum.map_join(names, ",", &quote_column/1)
    initial = {0, :crypto.hash_init(:sha256)}

    {count, source_hash} =
      Snapshot.fold!(db, "SELECT " <> select <> " FROM " <> table <> " ORDER BY id", initial, fn rows, {count, hash} ->
        rows = Enum.map(rows, &load_row(&1, columns, table))
        insert_rows!(table, select, rows)
        {count + length(rows), digest_rows(hash, rows)}
      end)

    {target_count, target_hash} = target_digest(table, select, 0, initial)

    if target_count != count or :crypto.hash_final(target_hash) != :crypto.hash_final(source_hash),
      do: Repo.rollback(:validation_mismatch)

    [[sequence]] = Repo.query!("SELECT pg_get_serial_sequence($1, 'id')", [table]).rows
    [[next_id]] = Repo.query!("SELECT GREATEST(COALESCE(MAX(id), 0) + 1, 1) FROM " <> table).rows
    # Unlike setval, RESTART rolls back with the surrounding transfer transaction.
    Repo.query!("ALTER SEQUENCE " <> sequence <> " RESTART WITH " <> to_string(max(next_id, source_next_id(db, table))))

    %{"rows" => count, "validated" => true}
  end

  defp load_row(row, columns, table) do
    executing = table == "oban_jobs" and Enum.at(row, Enum.find_index(columns, &(hd(&1) == "state"))) == "executing"

    Enum.zip(row, columns)
    |> Enum.map(fn {value, [column, type]} ->
      cond do
        executing and column == "state" ->
          "retryable"

        executing and column == "attempted_by" ->
          nil

        executing and column == "attempt" ->
          max(value - 1, 0)

        table == "media_items" and column == "subtitle_filepaths" ->
          load_sqlite_array(value, {:array, {:array, :string}})

        table == "oban_jobs" and column == "errors" ->
          load_sqlite_array(value, {:array, :map})

        true ->
          load_value(value, type)
      end
    end)
  end

  defp load_sqlite_array(value, type) do
    case Ecto.Type.adapter_load(Ecto.Adapters.SQLite3, type, value) do
      {:ok, decoded} -> decoded
      _ -> Snapshot.fail(:unsupported_column_type)
    end
  end

  defp source_next_id(db, table) do
    if Snapshot.query!(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='sqlite_sequence'") == [] do
      1
    else
      case Snapshot.query!(db, "SELECT seq FROM sqlite_sequence WHERE name=?", [table]) do
        [[seq]] when is_integer(seq) and seq >= 0 -> seq + 1
        [] -> 1
        _ -> Snapshot.fail(:unsupported_source_sequence)
      end
    end
  end

  defp insert_rows!(_table, _select, []), do: :ok

  defp insert_rows!(table, select, rows) do
    width = length(hd(rows))

    rows
    |> Enum.chunk_every(max(1, div(60_000, width)))
    |> Enum.each(fn chunk ->
      placeholders =
        for index <- 0..(length(chunk) - 1),
            do: "(" <> Enum.map_join(1..width, ",", &("$" <> to_string(index * width + &1))) <> ")"

      Repo.query!(
        "INSERT INTO " <> table <> " (" <> select <> ") VALUES " <> Enum.join(placeholders, ","),
        Enum.flat_map(chunk, & &1),
        log: false
      )
    end)
  end

  defp target_digest(table, select, offset, {count, hash}) do
    rows = Repo.query!("SELECT " <> select <> " FROM " <> table <> " ORDER BY id LIMIT 500 OFFSET $1", [offset]).rows
    next = {count + length(rows), digest_rows(hash, rows)}
    if length(rows) == 500, do: target_digest(table, select, offset + 500, next), else: next
  end

  defp digest_rows(hash, rows),
    do: Enum.reduce(rows, hash, &:crypto.hash_update(&2, :erlang.term_to_binary(canonical(&1))))

  defp canonical(%Date{} = value), do: {:date, Date.to_iso8601(value)}
  defp canonical(%DateTime{} = value), do: {:timestamp, DateTime.to_unix(value, :microsecond)}
  defp canonical(%NaiveDateTime{} = value), do: canonical(DateTime.from_naive!(value, "Etc/UTC"))
  defp canonical(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical(item)} end)

  defp canonical(value), do: value

  defp load_value(nil, _type), do: nil
  defp load_value(value, "bool") when value in [0, 1], do: value == 1
  defp load_value(value, type) when type in ["json", "jsonb"], do: Jason.decode!(value)
  defp load_value(value, "uuid"), do: Ecto.UUID.dump!(value)
  defp load_value(value, "date"), do: Date.from_iso8601!(value)
  defp load_value(value, "timestamp"), do: timestamp(value) |> DateTime.to_naive()
  defp load_value(value, "timestamptz"), do: timestamp(value)
  defp load_value(value, "numeric"), do: Decimal.new(to_string(value))
  defp load_value(value, "_" <> _type), do: Jason.decode!(value)

  defp load_value(value, type)
       when type in ["int2", "int4", "int8", "float4", "float8", "varchar", "text", "bytea", "oban_job_state"],
       do: value

  defp load_value(_value, _type), do: Snapshot.fail(:unsupported_column_type)

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> date
      _ -> value |> String.replace(" ", "T") |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp quote_column(name), do: "\"" <> name <> "\""
end
