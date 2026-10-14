defmodule Pinchflat.Repo.Migrations.AddMigrationReviewQueueState do
  use Ecto.Migration

  def change do
    alter table(:legacy_migration_records) do
      add :queue_pauses, :map
    end
  end
end
