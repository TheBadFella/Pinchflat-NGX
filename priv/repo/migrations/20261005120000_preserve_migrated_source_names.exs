defmodule Pinchflat.Repo.Migrations.PreserveMigratedSourceNames do
  use Ecto.Migration
  require Logger

  def up do
    state = Pinchflat.LegacyMigration.get_state()

    create_if_not_exists table(:legacy_migration_records) do
      add :provenance, :string, null: false
      add :status, :string, null: false
      add :original_max_version, :bigint
      add :original_source_count, :integer
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    if state.provenance == "legacy_pinchflat" do
      version = Map.fetch!(state, :original_max_version)
      source_count = Map.fetch!(state, :source_count)
      true = is_integer(version) and is_integer(source_count) and source_count >= 0
      adapter = Application.get_env(:pinchflat, :database_adapter, :sqlite)

      if adapter == :postgres do
        execute(
          "UPDATE sources SET custom_name_locked = true WHERE custom_name_locked = false OR custom_name_locked IS NULL;"
        )
      else
        execute(
          "UPDATE sources SET custom_name_locked = 1 WHERE custom_name_locked = 0 OR custom_name_locked IS NULL;"
        )
      end

      execute("""
      INSERT INTO legacy_migration_records (provenance, status, original_max_version, original_source_count, inserted_at, updated_at)
      VALUES ('legacy_pinchflat', 'pending_review', #{version}, #{source_count}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
      """)

      Logger.info(
        "[PreserveMigratedSourceNames] Preserved legacy source names by locking custom_name_locked"
      )
    else
      execute("""
      INSERT INTO legacy_migration_records (provenance, status, inserted_at, updated_at)
      VALUES ('existing_or_fresh', 'completed', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
      """)
    end
  end

  def down do
    drop_if_exists table(:legacy_migration_records)
  end
end
