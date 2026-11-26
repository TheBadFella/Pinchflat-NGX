defmodule Pinchflat.Repo.Migrations.AddKeepNewestCountToSources do
  use Ecto.Migration

  def up do
    if Pinchflat.Database.postgres?() do
      alter table(:sources) do
        add :keep_newest_count, :integer
      end

      execute(
        "ALTER TABLE sources ADD CONSTRAINT sources_keep_newest_count_check " <>
          "CHECK (keep_newest_count IS NULL OR keep_newest_count > 0)"
      )
    else
      execute(
        "ALTER TABLE sources ADD COLUMN keep_newest_count INTEGER " <>
          "CHECK (keep_newest_count IS NULL OR keep_newest_count > 0)"
      )
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      execute("ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_keep_newest_count_check")

      alter table(:sources) do
        remove :keep_newest_count
      end
    else
      execute("ALTER TABLE sources DROP COLUMN keep_newest_count")
    end
  end
end
