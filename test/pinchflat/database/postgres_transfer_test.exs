defmodule Pinchflat.Database.PostgresTransferTest do
  use Pinchflat.DataCase
  @moduletag :postgres_only
  alias Exqlite.Sqlite3
  alias Pinchflat.Database.PostgresMigration, as: Migration
  alias Pinchflat.Database.PostgresMigrationRecord, as: Record
  alias Pinchflat.Database.PostgresTransfer, as: Transfer
  alias Pinchflat.Database.SqliteSnapshot, as: Snapshot
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source

  setup do
    directory = Path.join(System.tmp_dir!(), "postgres-transfer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    source =
      Pinchflat.SourcesFixtures.source_fixture(%{enabled: false, custom_name: "Preserved 台", custom_name_locked: true})

    item =
      %MediaItem{}
      |> MediaItem.changeset(%{
        source_id: source.id,
        media_id: "existing",
        title: "Searchable library episode",
        original_url: "https://www.youtube.com/watch?v=existing",
        media_filepath: "/downloads/unchanged.mkv",
        media_size_bytes: 77,
        media_downloaded_at: ~U[2026-01-02 03:04:05Z],
        uploaded_at: ~U[2026-01-01 00:00:00Z],
        subtitle_filepaths: [["en", "/downloads/unchanged.en.srt"]],
        prevent_culling: true
      })
      |> Repo.insert!()

    Repo.query!("UPDATE media_items SET details_updated_at = $1 WHERE id = $2", [~N[2026-01-03 01:02:03], item.id])

    jobs =
      for state <- ["available", "completed", "executing", "scheduled", "retryable", "cancelled", "discarded"] do
        job =
          Pinchflat.JobFixtures.job_fixture()
          |> Ecto.Changeset.change(state: state, attempt: 3, attempted_by: ["owned-node-194"])
          |> Repo.update!()

        Pinchflat.Tasks.create_task(job, source)
        job
      end

    path = Path.join(directory, "source.db")
    build_sqlite_fixture(path)
    Enum.each(Enum.reverse(Snapshot.tables()), &Repo.query!("DELETE FROM " <> &1))
    Repo.insert!(%Record{id: 1, status: "running"})
    old_hold = Application.get_env(:pinchflat, :postgres_migration_boot_held)

    on_exit(fn ->
      File.rm_rf!(directory)
      Application.put_env(:pinchflat, :postgres_migration_boot_held, old_hold || false)
    end)

    %{
      path: path,
      directory: directory,
      source: source,
      item: item,
      interrupted_job: Enum.find(jobs, &(&1.state == "executing"))
    }
  end

  test "validates every field, preserves IDs, paths and history, rebuilds search and resets sequences", ctx do
    before = File.read!(ctx.path)
    assert {:ok, report} = Transfer.run(ctx.path, ctx.directory)
    assert File.read!(ctx.path) == before
    assert Enum.all?(report["tables"], fn {_table, result} -> result["validated"] end)
    assert report["library"] == %{"downloaded_items" => 1, "recorded_bytes" => 77, "missing_media_files" => 1}
    assert Repo.get!(Source, ctx.source.id).custom_name == "Preserved 台"
    assert Repo.get!(Source, ctx.source.id).enabled == false
    assert Repo.get!(MediaItem, ctx.item.id).subtitle_filepaths == [["en", "/downloads/unchanged.en.srt"]]
    assert Repo.get!(MediaItem, ctx.item.id).uuid == ctx.item.uuid
    assert Repo.query!("SELECT details_updated_at FROM media_items").rows == [[~N[2026-01-03 01:02:03]]]

    assert Repo.query!(
             "SELECT count(*) FROM media_items WHERE search_vector @@ plainto_tsquery('simple', 'searchable')"
           ).rows == [[1]]

    assert Repo.query!("SELECT state::text FROM oban_jobs ORDER BY id").rows == [
             ["available"],
             ["completed"],
             ["retryable"],
             ["scheduled"],
             ["retryable"],
             ["cancelled"],
             ["discarded"]
           ]

    interrupted = Repo.get!(Oban.Job, ctx.interrupted_job.id)
    assert interrupted.attempt == 2
    assert interrupted.attempted_by == nil
    assert Repo.aggregate(Pinchflat.Tasks.Task, :count) == 7

    assert Migration.record().status == "pending_review"
    new = Pinchflat.SourcesFixtures.source_fixture()
    assert new.id > ctx.source.id
    assert {:error, :target_not_empty} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.get!(MediaItem, ctx.item.id).title == ctx.item.title
  end

  test "preserves populated cutoff dates and validates their field digests", ctx do
    edit_source(ctx.path, "UPDATE sources SET download_cutoff_date = '2024-02-29', index_cutoff_date = '2026-10-07'")
    assert {:ok, report} = Transfer.run(ctx.path, ctx.directory)
    assert report["tables"]["sources"]["validated"]
    retained = Repo.get!(Source, ctx.source.id)
    assert retained.download_cutoff_date == ~D[2024-02-29]
    assert retained.index_cutoff_date == ~D[2026-10-07]
  end

  test "transfers nullable profile retention and explicit source overrides", ctx do
    edit_source(ctx.path, "UPDATE media_profiles SET retention_period_days = 3 WHERE id = #{ctx.source.media_profile_id}")
    assert {:ok, report} = Transfer.run(ctx.path, ctx.directory)
    assert report["tables"]["media_profiles"]["validated"]
    assert Repo.get!(Pinchflat.Profiles.MediaProfile, ctx.source.media_profile_id).retention_period_days == 3
    assert Repo.get!(Source, ctx.source.id).retention_period_days == nil
    protected = Repo.get!(MediaItem, ctx.item.id)
    refute Pinchflat.Media.retention_cullable?(protected)
    protected |> Ecto.Changeset.change(prevent_culling: false) |> Repo.update!()
    assert Pinchflat.Media.retention_cullable?(protected)
  end

  test "copies current sharing credentials and preserves revocation", ctx do
    edit_source(ctx.path, """
    CREATE TABLE IF NOT EXISTS share_tokens (
      id INTEGER PRIMARY KEY, name TEXT, token_digest TEXT, media_profile_id INTEGER,
      revoked_at TEXT, expires_at TEXT, last_used_at TEXT, inserted_at TEXT, updated_at TEXT
    );
    INSERT INTO share_tokens (id,name,token_digest,media_profile_id,revoked_at,inserted_at,updated_at)
    VALUES (71,'Retained token','fixture-digest',#{ctx.source.media_profile_id},
            '2026-10-01 00:00:00','2026-09-01 00:00:00','2026-10-01 00:00:00');
    """)

    assert {:ok, report} = Transfer.run(ctx.path, ctx.directory)
    assert report["tables"]["share_tokens"] == %{"rows" => 1, "validated" => true}

    assert Repo.query!("SELECT media_profile_id, revoked_at IS NOT NULL FROM share_tokens WHERE id=71").rows ==
             [[ctx.source.media_profile_id, true]]
  end

  test "loads subtitles serialized by the SQLite adapter", ctx do
    encoded = Jason.encode!([Jason.encode!(["en", "/downloads/unchanged.en.srt"])])

    {:ok, db} = Sqlite3.open(ctx.path, mode: :readwrite)

    try do
      Snapshot.query!(db, "UPDATE media_items SET subtitle_filepaths=?", [encoded])
    after
      Sqlite3.close(db)
    end

    assert {:ok, _} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.get!(MediaItem, ctx.item.id).subtitle_filepaths == [["en", "/downloads/unchanged.en.srt"]]
  end

  test "preserves retired SQLite IDs above the highest surviving row", ctx do
    edit_source(ctx.path, """
    UPDATE sqlite_sequence SET seq=9000000 WHERE name='sources';
    """)

    assert {:ok, _} = Transfer.run(ctx.path, ctx.directory)
    assert Pinchflat.SourcesFixtures.source_fixture().id == 9_000_001
  end

  test "loads job error maps serialized by the SQLite adapter", ctx do
    errors = [%{"attempt" => 1, "error" => "Synthetic retry error", "at" => "2026-10-18T00:00:00Z"}]
    {:ok, encoded} = Ecto.Type.adapter_dump(Ecto.Adapters.SQLite3, {:array, :map}, errors)
    {:ok, db} = Sqlite3.open(ctx.path, mode: :readwrite)

    try do
      Snapshot.query!(db, "UPDATE oban_jobs SET errors=? WHERE id=?", [encoded, ctx.interrupted_job.id])
    after
      Sqlite3.close(db)
    end

    assert {:ok, _} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.get!(Oban.Job, ctx.interrupted_job.id).errors == errors
  end

  test "late failure rolls back sequence changes as well as copied rows", ctx do
    Repo.query!("ALTER SEQUENCE sources_id_seq RESTART WITH 8000000")
    before = Repo.query!("SELECT last_value, is_called FROM sources_id_seq").rows
    edit_source(ctx.path, "ALTER TABLE tasks ADD COLUMN unsupported_fixture TEXT")

    assert {:error, :unsupported_source_columns} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.query!("SELECT last_value, is_called FROM sources_id_seq").rows == before
    assert Repo.aggregate(Source, :count) == 0
  end

  test "an unfinished legacy review cannot be bypassed through transfer", ctx do
    edit_source(ctx.path, "UPDATE legacy_migration_records SET status='pending_review'")
    assert {:error, :legacy_review_pending} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.aggregate(Source, :count) == 0
  end

  test "refuses fractional timestamps that cannot be preserved in the target schema", ctx do
    edit_source(ctx.path, "UPDATE media_items SET details_updated_at = '2026-10-07T01:02:03.123456'")
    assert {:error, :validation_mismatch} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.aggregate(Source, :count) == 0
    assert Repo.aggregate(MediaItem, :count) == 0
    assert Migration.record().status == "running"
  end

  test "rejects a populated target without deleting its library", ctx do
    existing = Pinchflat.SourcesFixtures.source_fixture()
    assert {:error, :target_not_empty} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.get!(Source, existing.id).custom_name == existing.custom_name
    assert Repo.aggregate(MediaItem, :count) == 0
  end

  test "rejects older schemas before changing the target", ctx do
    edit_source(ctx.path, "DELETE FROM schema_migrations WHERE version = (SELECT MAX(version) FROM schema_migrations)")
    assert {:error, :unsupported_source_version} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.aggregate(Source, :count) == 0
  end

  test "unknown columns late in the transfer roll back earlier copied tables", ctx do
    edit_source(ctx.path, "ALTER TABLE tasks ADD COLUMN future_data TEXT")
    assert {:error, :unsupported_source_columns} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.aggregate(Source, :count) == 0
    assert Repo.aggregate(MediaItem, :count) == 0
    assert Migration.record().status == "running"
  end

  test "database exceptions roll back all copied tables", ctx do
    Repo.query!(
      "CREATE FUNCTION reject_transfer_lab() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'owned transfer rejection'; END; $$ LANGUAGE plpgsql"
    )

    Repo.query!(
      "CREATE TRIGGER reject_transfer_lab BEFORE INSERT ON tasks FOR EACH ROW EXECUTE FUNCTION reject_transfer_lab()"
    )

    assert {:error, :transfer_failed} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.aggregate(Source, :count) == 0
    assert Repo.aggregate(MediaItem, :count) == 0
    assert Migration.record().status == "running"
  end

  test "chunked copying validates more than one batch", ctx do
    {:ok, db} = Sqlite3.open(ctx.path, mode: :readwrite)

    try do
      names = Snapshot.query!(db, "PRAGMA table_info(media_items)") |> Enum.map(&Enum.at(&1, 1))
      [original] = Snapshot.query!(db, "SELECT * FROM media_items")

      for index <- 1..501 do
        values =
          Enum.zip(names, original)
          |> Enum.map(fn
            {"id", value} -> value + index
            {"media_id", _} -> "chunk-#{index}"
            {"uuid", _} -> Ecto.UUID.generate()
            {_field, value} -> value
          end)

        Snapshot.query!(
          db,
          "INSERT INTO media_items VALUES (" <> Enum.map_join(values, ",", fn _ -> "?" end) <> ")",
          values
        )
      end
    after
      Sqlite3.close(db)
    end

    assert {:ok, report} = Transfer.run(ctx.path, ctx.directory)
    assert report["tables"]["media_items"]["rows"] == 502
    assert Repo.aggregate(MediaItem, :count) == 502
  end

  test "copied notification credentials are not written to SQL logs", ctx do
    {:ok, db} = Sqlite3.open(ctx.path, mode: :readwrite)

    try do
      Snapshot.query!(db, "UPDATE settings SET apprise_server = ?", [
        "https://lab:SECRET_TRANSFER_87@example.invalid/hook/SECRET_TRANSFER_87"
      ])
    after
      Sqlite3.close(db)
    end

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:ok, _} = Transfer.run(ctx.path, ctx.directory) end)

      assert log =~ "LOCK TABLE"
      refute log =~ "SECRET_TRANSFER_87"
      assert Pinchflat.Settings.get!(:apprise_server) =~ "SECRET_TRANSFER_87"
    after
      Logger.configure(level: previous_level)
    end
  end

  test "missing source does not create a replacement SQLite file", ctx do
    path = Path.join(ctx.directory, "missing.db")
    assert {:error, :source_unavailable} = Transfer.run(path, ctx.directory)
    refute File.exists?(path)
    assert Repo.aggregate(Source, :count) == 0
  end

  test "broken source relationships are rejected before copying", ctx do
    edit_source(ctx.path, "UPDATE media_items SET source_id = 99999999")
    assert {:error, :source_foreign_keys} = Transfer.run(ctx.path, ctx.directory)
    assert Repo.aggregate(Source, :count) == 0
  end

  test "review records queue choices durably but holds this process until restart", ctx do
    assert {:ok, _} = Transfer.run(ctx.path, ctx.directory)
    Migration.initialize!()
    assert Migration.pending?()
    assert {:error, :invalid_queues} = Migration.complete(["unknown"])
    assert :ok = Migration.complete(["media_fetching"])
    assert Migration.record().paused_queues == ["media_fetching"]
    assert Migration.pending?()
    Migration.initialize!()
    refute Migration.pending?()
    assert {:error, :not_ready} = Migration.complete([])
  end

  defp edit_source(path, sql) do
    {:ok, db} = Sqlite3.open(path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(db, sql)
    after
      Sqlite3.close(db)
    end
  end

  defp build_sqlite_fixture(path) do
    {:ok, db} = Sqlite3.open(path)

    try do
      for table <- Snapshot.tables() do
        columns =
          Repo.query!(
            "SELECT column_name, udt_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position",
            [table]
          ).rows
          |> Enum.reject(&(hd(&1) == "search_vector"))

        names = Enum.map_join(columns, ",", fn [name, _] -> "\"" <> name <> "\"" end)

        definitions =
          Enum.map_join(columns, ",", fn
            ["id", _] -> "id INTEGER PRIMARY KEY AUTOINCREMENT"
            [name, _] -> "\"" <> name <> "\""
          end)

        foreign_key = if table == "media_items", do: ", FOREIGN KEY(source_id) REFERENCES sources(id)", else: ""
        :ok = Sqlite3.execute(db, "CREATE TABLE " <> table <> " (" <> definitions <> foreign_key <> ")")
        rows = Repo.query!("SELECT " <> names <> " FROM " <> table <> " ORDER BY id").rows

        Enum.each(rows, fn row ->
          params = Enum.zip(row, columns) |> Enum.map(fn {value, [name, type]} -> sqlite_value(value, name, type) end)

          Snapshot.query!(
            db,
            "INSERT INTO " <> table <> " VALUES (" <> Enum.map_join(params, ",", fn _ -> "?" end) <> ")",
            params
          )
        end)
      end

      :ok = Sqlite3.execute(db, "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY)")

      Application.app_dir(:pinchflat, "priv/repo/migrations")
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.each(fn path ->
        version = Path.basename(path) |> String.split("_") |> hd() |> String.to_integer()
        if version != 20_261_007_120_000, do: Snapshot.query!(db, "INSERT INTO schema_migrations VALUES (?)", [version])
      end)
    after
      Sqlite3.close(db)
    end
  end

  defp sqlite_value(value, "subtitle_filepaths", _type),
    do: Ecto.Type.adapter_dump(Ecto.Adapters.SQLite3, {:array, {:array, :string}}, value) |> elem(1)

  defp sqlite_value(value, "errors", _type),
    do: Ecto.Type.adapter_dump(Ecto.Adapters.SQLite3, {:array, :map}, value) |> elem(1)

  defp sqlite_value(value, _name, type), do: sqlite_value(value, type)
  defp sqlite_value(nil, _type), do: nil
  defp sqlite_value(value, "bool"), do: if(value, do: 1, else: 0)
  defp sqlite_value(value, "uuid"), do: Ecto.UUID.load!(value)
  defp sqlite_value(%DateTime{} = value, _type), do: DateTime.to_iso8601(value)
  defp sqlite_value(%NaiveDateTime{} = value, _type), do: NaiveDateTime.to_iso8601(value)
  defp sqlite_value(value, "_" <> _type), do: Jason.encode!(value)
  defp sqlite_value(value, type) when type in ["json", "jsonb"], do: Jason.encode!(value)
  defp sqlite_value(value, _type), do: value
end
