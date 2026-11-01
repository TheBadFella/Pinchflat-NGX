defmodule Pinchflat.Database.WatchTransitionMigrationTest do
  use ExUnit.Case, async: false
  @moduletag :sqlite_only

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  test "upgrade retains a prior confirmed incident and rollback cannot silently forget it" do
    migration = Pinchflat.Repo.Migrations.TrackConfirmedWatchTransitions

    unless Code.ensure_loaded?(migration),
      do: Code.require_file("priv/repo/migrations/20261026120000_track_confirmed_watch_transitions.exs")

    directory = Path.join(System.tmp_dir!(), "watch-transition-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    start_supervised!({FixtureRepo, database: Path.join(directory, "fixture.db")})
    on_exit(fn -> File.rm_rf!(directory) end)

    FixtureRepo.query!("""
    CREATE TABLE media_watches (id INTEGER PRIMARY KEY, confirmed_state TEXT,
      suspected_kind TEXT, suspected_value TEXT, baseline_upstream_duration_seconds INTEGER,
      hold_at TEXT, updated_at TEXT)
    """)

    FixtureRepo.query!("""
    INSERT INTO media_watches VALUES
      (1, 'confirmed', 'duration', '130', 120, '2026-10-25 12:00:00', '2026-10-25 13:00:00')
    """)

    version = 20_261_026_120_000
    assert [^version] = Ecto.Migrator.run(FixtureRepo, [{version, migration}], :up, step: 1)

    assert [[130, "2026-10-25 12:00:00", nil]] =
             FixtureRepo.query!(
               "SELECT current_upstream_duration_seconds, confirmed_change_at, released_at FROM media_watches"
             ).rows

    newer = Pinchflat.Repo.Migrations.TrackApprovedWatchFilesAndDuration

    unless Code.ensure_loaded?(newer),
      do: Code.require_file("priv/repo/migrations/20261027120000_track_approved_watch_files_and_duration.exs")

    next_version = 20_261_027_120_000
    assert [^next_version] = Ecto.Migrator.run(FixtureRepo, [{next_version, newer}], :up, step: 1)

    assert [[130, nil]] =
             FixtureRepo.query!("SELECT confirmed_upstream_duration_seconds, approved_active_files FROM media_watches").rows

    FixtureRepo.query!("ALTER TABLE media_watches ADD COLUMN current_visibility TEXT")
    FixtureRepo.query!("ALTER TABLE media_watches ADD COLUMN current_reason TEXT")

    FixtureRepo.query!(
      "UPDATE media_watches SET current_visibility='public', current_reason='unused', suspected_kind='unavailable', suspected_value='private', confirmed_state='suspected'"
    )

    visibility_migration = Pinchflat.Repo.Migrations.TrackObservedWatchVisibility

    unless Code.ensure_loaded?(visibility_migration),
      do: Code.require_file("priv/repo/migrations/20261027130000_track_observed_watch_visibility.exs")

    visibility_version = 20_261_027_130_000

    assert [^visibility_version] =
             Ecto.Migrator.run(FixtureRepo, [{visibility_version, visibility_migration}], :up, step: 1)

    assert [["public", "private"]] =
             FixtureRepo.query!("SELECT current_visibility, observed_visibility FROM media_watches").rows

    refute "current_reason" in Enum.map(FixtureRepo.query!("PRAGMA table_info(media_watches)").rows, &Enum.at(&1, 1))

    assert_raise RuntimeError, ~r/refusing rollback/, fn ->
      Ecto.Migrator.run(FixtureRepo, [{version, migration}], :down, step: 1)
    end

    assert version in Ecto.Migrator.migrated_versions(FixtureRepo)
  end
end
