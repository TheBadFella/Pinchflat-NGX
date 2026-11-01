defmodule Pinchflat.Repo.Migrations.AddWatchWindowDaysToProfilesAndSources do
  use Ecto.Migration

  def up do
    adapter = Application.get_env(:pinchflat, :database_adapter, :sqlite)

    if adapter == :sqlite do
      execute(
        "ALTER TABLE media_profiles ADD COLUMN watch_window_days INTEGER NOT NULL DEFAULT 0 CHECK (watch_window_days >= 0 AND watch_window_days <= 365)"
      )

      execute(
        "ALTER TABLE sources ADD COLUMN watch_window_days INTEGER CHECK (watch_window_days IS NULL OR (watch_window_days >= 0 AND watch_window_days <= 365))"
      )
    else
      alter table(:media_profiles) do
        add :watch_window_days, :integer, null: false, default: 0
      end

      alter table(:sources) do
        add :watch_window_days, :integer
      end

      execute(
        "ALTER TABLE media_profiles ADD CONSTRAINT media_profiles_watch_window_days_check CHECK (watch_window_days >= 0 AND watch_window_days <= 365)"
      )

      execute(
        "ALTER TABLE sources ADD CONSTRAINT sources_watch_window_days_check CHECK (watch_window_days IS NULL OR (watch_window_days >= 0 AND watch_window_days <= 365))"
      )
    end
  end

  def down do
    adapter = Application.get_env(:pinchflat, :database_adapter, :sqlite)

    if adapter == :sqlite do
      raise "SQLite watch policy rollback requires a full table rebuild; refusing to mark a partial rollback successful"
    else
      execute("ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_watch_window_days_check")

      execute(
        "ALTER TABLE media_profiles DROP CONSTRAINT IF EXISTS media_profiles_watch_window_days_check"
      )

      alter table(:sources) do
        remove :watch_window_days
      end

      alter table(:media_profiles) do
        remove :watch_window_days
      end
    end
  end
end
