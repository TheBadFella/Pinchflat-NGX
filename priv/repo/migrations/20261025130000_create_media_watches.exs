defmodule Pinchflat.Repo.Migrations.CreateMediaWatches do
  use Ecto.Migration

  def up do
    create table(:media_watches) do
      add :media_item_id, references(:media_items, on_delete: :nilify_all)
      add :media_item_uuid, :uuid, null: false
      add :media_id, :string, null: false
      add :source_id, :integer
      add :source_uuid, :uuid

      add :started_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      add :baseline_upstream_duration_seconds, :integer
      add :baseline_visibility, :string

      add :next_check_at, :utc_datetime
      add :last_observed_at, :utc_datetime
      add :last_success_at, :utc_datetime
      add :last_error_at, :utc_datetime

      add :current_visibility, :string
      add :current_reason, :string

      add :suspected_kind, :string
      add :suspected_value, :string
      add :suspected_first_seen_at, :utc_datetime
      add :suspected_count, :integer, default: 0

      add :confirmed_state, :string, null: false, default: "unchanged"

      add :observation_version, :integer, null: false, default: 0

      add :hold_reason, :string
      add :hold_at, :utc_datetime

      add :original_manifest_path, :string
      add :archive_state, :string, null: false, default: "none"

      add :operation_kind, :string
      add :operation_id, :uuid
      add :lease_owner, :string
      add :lease_generation, :integer, default: 0
      add :lease_expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_watches, [:media_item_id])
    create index(:media_watches, [:next_check_at])
    create index(:media_watches, [:ends_at])
    create index(:media_watches, [:archive_state])

    create table(:media_watch_events) do
      add :media_watch_id, references(:media_watches, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :fingerprint, :string, null: false
      add :observed_at, :utc_datetime, null: false
      add :old_value, :string
      add :new_value, :string
      add :delivery_state, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :error_summary, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_watch_events, [:media_watch_id, :kind, :fingerprint])
    create index(:media_watch_events, [:delivery_state, :next_attempt_at])
    create index(:media_watch_events, [:media_watch_id])

    adapter = Application.get_env(:pinchflat, :database_adapter, :sqlite)

    if adapter == :postgres do
      execute(
        "ALTER TABLE media_watches ADD CONSTRAINT media_watches_archive_state_check CHECK (archive_state IN ('none','preparing','published','needs_recovery'))"
      )

      execute(
        "ALTER TABLE media_watches ADD CONSTRAINT media_watches_confirmed_state_check CHECK (confirmed_state IN ('unchanged','suspected','confirmed'))"
      )
    else
      execute(
        "CREATE TRIGGER media_watches_archive_state_check BEFORE INSERT ON media_watches BEGIN SELECT CASE WHEN NEW.archive_state NOT IN ('none','preparing','published','needs_recovery') THEN RAISE(ABORT, 'invalid archive_state') END; END;"
      )

      execute(
        "CREATE TRIGGER media_watches_archive_state_check_update BEFORE UPDATE ON media_watches BEGIN SELECT CASE WHEN NEW.archive_state NOT IN ('none','preparing','published','needs_recovery') THEN RAISE(ABORT, 'invalid archive_state') END; END;"
      )

      execute(
        "CREATE TRIGGER media_watches_confirmed_state_check BEFORE INSERT ON media_watches BEGIN SELECT CASE WHEN NEW.confirmed_state NOT IN ('unchanged','suspected','confirmed') THEN RAISE(ABORT, 'invalid confirmed_state') END; END;"
      )

      execute(
        "CREATE TRIGGER media_watches_confirmed_state_check_update BEFORE UPDATE ON media_watches BEGIN SELECT CASE WHEN NEW.confirmed_state NOT IN ('unchanged','suspected','confirmed') THEN RAISE(ABORT, 'invalid confirmed_state') END; END;"
      )
    end
  end

  def down do
    drop_if_exists table(:media_watch_events)
    drop_if_exists table(:media_watches)
  end
end
