defmodule Pinchflat.Database.PostgresTransfer do
  @moduledoc "One explicit, transactional transfer from a retained SQLite snapshot."
  require Logger

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
    error ->
      # Exception messages and query parameters can contain copied credentials.
      Logger.error("PostgreSQL transfer failed: #{safe_error(error)}")
      {:error, :transfer_failed}
  catch
    {:migration_error, reason} -> {:error, reason}
  end

  defp safe_error(%Postgrex.Error{postgres: %{code: code}}), do: "Postgrex.Error (#{code})"
  defp safe_error(error), do: inspect(error.__struct__)

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
        "SELECT COUNT(*), COALESCE(SUM(media_size_bytes), 0)::bigint FROM media_items WHERE media_downloaded_at IS NOT NULL"
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
        "SELECT column_name, udt_name, datetime_precision FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position",
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

    {target_count, target_hash} = target_digest(table, names, nil, initial)

    count_mismatch = target_count != count
    hash_mismatch = :crypto.hash_final(target_hash) != :crypto.hash_final(source_hash)

    if count_mismatch or hash_mismatch do
      mismatch = if count_mismatch, do: "count", else: "hash"

      detail =
        if hash_mismatch and not count_mismatch do
          find_mismatch_detail(db, table, names, columns, nil)
        else
          nil
        end

      detail_log =
        if detail do
          " row_id=#{detail["row_id"]} column=#{detail["column"]} source_type=#{detail["source_type"]} target_type=#{detail["target_type"]}"
        else
          ""
        end

      Logger.error(
        "PostgreSQL transfer validation failed: table=#{table} source_count=#{count} target_count=#{target_count} mismatch=#{mismatch}#{detail_log}"
      )

      payload =
        %{
          "error" => "validation_mismatch",
          "table" => table,
          "source_count" => count,
          "target_count" => target_count,
          "mismatch_type" => mismatch
        }
        |> then(fn m -> if detail, do: Map.merge(m, detail), else: m end)

      Repo.rollback(payload)
    end

    [[sequence]] = Repo.query!("SELECT pg_get_serial_sequence($1, 'id')", [table]).rows
    [[next_id]] = Repo.query!("SELECT GREATEST(COALESCE(MAX(id), 0) + 1, 1) FROM " <> table).rows
    # Unlike setval, RESTART rolls back with the surrounding transfer transaction.
    Repo.query!("ALTER SEQUENCE " <> sequence <> " RESTART WITH " <> to_string(max(next_id, source_next_id(db, table))))

    %{"rows" => count, "validated" => true}
  end

  defp load_row(row, columns, table) do
    executing = table == "oban_jobs" and Enum.at(row, Enum.find_index(columns, &(hd(&1) == "state"))) == "executing"

    Enum.zip(row, columns)
    |> Enum.map(fn {value, [column, type, precision]} ->
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

        not is_nil(value) and type in ["timestamp", "timestamptz"] and precision == 0 ->
          value |> load_value(type) |> truncate_timestamp()

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

  defp target_digest(table, names, last_id, {count, hash}) do
    select = Enum.map_join(names, ",", &quote_column/1)
    {where, params} = if is_nil(last_id), do: {"", []}, else: {" WHERE id > $1", [last_id]}
    rows = Repo.query!("SELECT " <> select <> " FROM " <> table <> where <> " ORDER BY id LIMIT 500", params).rows
    next = {count + length(rows), digest_rows(hash, rows)}

    if length(rows) == 500,
      do: target_digest(table, names, Enum.at(List.last(rows), Enum.find_index(names, &(&1 == "id"))), next),
      else: next
  end

  defp find_mismatch_detail(db, table, names, columns, last_id) do
    select = Enum.map_join(names, ",", &quote_column/1)
    {pg_where, pg_params} = if is_nil(last_id), do: {"", []}, else: {" WHERE id > $1", [last_id]}
    {sqlite_where, sqlite_params} = if is_nil(last_id), do: {"", []}, else: {" WHERE id > ?", [last_id]}

    sqlite_rows =
      Snapshot.query!(
        db,
        "SELECT " <> select <> " FROM " <> table <> sqlite_where <> " ORDER BY id LIMIT 500",
        sqlite_params
      )
      |> Enum.map(&load_row(&1, columns, table))

    pg_rows =
      Repo.query!("SELECT " <> select <> " FROM " <> table <> pg_where <> " ORDER BY id LIMIT 500", pg_params).rows

    id_index = Enum.find_index(names, &(&1 == "id"))

    mismatch =
      Enum.zip(sqlite_rows, pg_rows)
      |> Enum.find_value(fn {src_row, tgt_row} ->
        if :erlang.term_to_binary(canonical(src_row)) != :erlang.term_to_binary(canonical(tgt_row)) do
          row_id = if id_index, do: Enum.at(tgt_row, id_index), else: nil

          Enum.zip([names, src_row, tgt_row])
          |> Enum.find_value(fn {col_name, s_val, t_val} ->
            if :erlang.term_to_binary(canonical(s_val)) != :erlang.term_to_binary(canonical(t_val)) do
              %{
                "row_id" => row_id,
                "column" => col_name,
                "source_type" => safe_value_type(s_val),
                "target_type" => safe_value_type(t_val)
              }
            end
          end)
        end
      end)

    cond do
      not is_nil(mismatch) ->
        mismatch

      length(sqlite_rows) == 500 and not is_nil(id_index) ->
        next_id = Enum.at(List.last(sqlite_rows), id_index)
        find_mismatch_detail(db, table, names, columns, next_id)

      true ->
        nil
    end
  end

  defp safe_value_type(nil), do: "nil"
  defp safe_value_type(v) when is_integer(v), do: "integer"
  defp safe_value_type(v) when is_float(v), do: "float"
  defp safe_value_type(v) when is_binary(v), do: "binary"
  defp safe_value_type(v) when is_boolean(v), do: "boolean"
  defp safe_value_type(%DateTime{}), do: "DateTime"
  defp safe_value_type(%NaiveDateTime{}), do: "NaiveDateTime"
  defp safe_value_type(%Date{}), do: "Date"
  defp safe_value_type(%Decimal{}), do: "Decimal"
  defp safe_value_type(v) when is_list(v), do: "list"
  defp safe_value_type(v) when is_map(v), do: "map"
  defp safe_value_type(_), do: "unknown"

  defp truncate_timestamp(%DateTime{} = value), do: DateTime.truncate(value, :second)
  defp truncate_timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.truncate(value, :second)

  defp digest_rows(hash, rows),
    do: Enum.reduce(rows, hash, &:crypto.hash_update(&2, :erlang.term_to_binary(canonical(&1))))

  defp canonical(value) when is_float(value), do: normalize_float(value)
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

  defp load_value(value, type) when type in ["float4", "float8"] and is_integer(value),
    do: normalize_float(value * 1.0)

  defp load_value(value, type) when type in ["float4", "float8"] and is_float(value),
    do: normalize_float(value)

  defp load_value(value, type) when type in ["float4", "float8"] and is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> normalize_float(parsed)
      :error -> Snapshot.fail(:unsupported_column_type)
    end
  end

  defp load_value(value, type)
       when type in ["int2", "int4", "int8", "varchar", "text", "bytea", "oban_job_state"],
       do: value

  defp load_value(_value, _type), do: Snapshot.fail(:unsupported_column_type)

  defp normalize_float(value) when is_float(value) do
    if value == 0.0, do: 0.0, else: value
  end

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> date
      _ -> value |> String.replace(" ", "T") |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp quote_column(name), do: "\"" <> name <> "\""
end
