# Run in a separate BEAM with DATABASE_ADAPTER=sqlite. Pinchflat.Database
# chooses its adapter at compile time, so a PostgreSQL test process cannot
# execute historical SQLite migrations by changing application env alone.
Application.ensure_all_started(:ecto_sql)

defmodule Pinchflat.TestSqliteTransferRepo do
  use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
end

args = System.argv()
path = List.last(args)
extensions = Application.get_env(:pinchflat, Pinchflat.Repo)[:load_extensions]
{:ok, repo} = Pinchflat.TestSqliteTransferRepo.start_link(database: path, load_extensions: extensions)

if "--native" in args do
  # Populate a native SQLite library before watch policy/state existed, then
  # upgrade it with the same historical migrations as an installed library.
  Ecto.Migrator.run(Pinchflat.TestSqliteTransferRepo, "priv/repo/migrations", :up, to: 20_261_024_140_000)

  Pinchflat.TestSqliteTransferRepo.query!("""
  INSERT INTO media_profiles (id, name, output_path_template, inserted_at, updated_at)
  VALUES (40, 'Native library', '{{title}}.{{ext}}', '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
         (41, 'Default off', '{{title}}.{{ext}}', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
  """)

  Pinchflat.TestSqliteTransferRepo.query!("""
  INSERT INTO sources (id, uuid, custom_name, collection_name, collection_id, collection_type,
                       original_url, media_profile_id, inserted_at, updated_at)
  VALUES (83, '00000000-0000-4000-8000-000000000083', 'Native inherited', 'Native', 'native-83',
          'channel', 'https://www.youtube.com/@native83', 40, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
         (84, '00000000-0000-4000-8000-000000000084', 'Native zero', 'Native', 'native-84',
          'channel', 'https://www.youtube.com/@native84', 40, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
         (85, '00000000-0000-4000-8000-000000000085', 'Native positive', 'Native', 'native-85',
          'channel', 'https://www.youtube.com/@native85', 40, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
  """)

  Pinchflat.TestSqliteTransferRepo.query!("""
  INSERT INTO media_items (id, uuid, media_id, title, original_url, source_id,
                           media_filepath, media_downloaded_at, uploaded_at, inserted_at, updated_at)
  VALUES (111, '00000000-0000-4000-8000-000000000111', 'native-media', 'Native artifact',
          'https://www.youtube.com/watch?v=native-media', 83, '/downloads/native.mkv',
          '2026-01-02 03:04:05', '2026-01-01 00:00:00', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
  """)

  Pinchflat.TestSqliteTransferRepo.query!("UPDATE legacy_migration_records SET status='completed'")
end

Ecto.Migrator.run(Pinchflat.TestSqliteTransferRepo, "priv/repo/migrations", :up, all: true)

if "--native" in args do
  Pinchflat.TestSqliteTransferRepo.query!("UPDATE media_profiles SET watch_window_days=14 WHERE id=40")
  Pinchflat.TestSqliteTransferRepo.query!("UPDATE sources SET watch_window_days=0 WHERE id=84")
  Pinchflat.TestSqliteTransferRepo.query!("UPDATE sources SET watch_window_days=7 WHERE id=85")

  Pinchflat.TestSqliteTransferRepo.query!("""
  INSERT INTO media_watches (id, media_item_id, media_item_uuid, media_id, source_id, source_uuid,
     started_at, ends_at, original_manifest_path, archive_state, confirmed_state,
     observation_version, lease_generation, inserted_at, updated_at)
  VALUES (120, 111, '00000000-0000-4000-8000-000000000111', 'native-media', 83,
     '00000000-0000-4000-8000-000000000083', '2026-01-02 03:04:05', '2026-01-16 03:04:05',
     '.pinchflat-originals/120/manifest.json', 'published', 'unchanged', 0, 0,
     '2026-01-02 03:04:05', '2026-01-02 03:04:05')
  """)

  Pinchflat.TestSqliteTransferRepo.query!("""
  INSERT INTO media_watch_events (id, media_watch_id, kind, fingerprint, observed_at,
                                   delivery_state, attempts, inserted_at, updated_at)
  VALUES (135, 120, 'edited', 'native-fingerprint', '2026-01-03 04:00:00',
          'pending', 0, '2026-01-03 04:00:00', '2026-01-03 04:00:00')
  """)

  for {table, high_water} <- [{"sources", 300}, {"media_watches", 400}, {"media_watch_events", 500}] do
    Pinchflat.TestSqliteTransferRepo.query!("UPDATE sqlite_sequence SET seq=? WHERE name=?", [high_water, table])
  end
end

Supervisor.stop(repo)
