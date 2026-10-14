defmodule Pinchflat.Repo.Migrations.AddMigrationArtworkRepairs do
  use Ecto.Migration

  def change do
    alter table(:legacy_migration_records) do
      add :artwork_repairs, :map
    end
  end
end
