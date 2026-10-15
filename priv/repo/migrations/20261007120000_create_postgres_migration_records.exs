defmodule Pinchflat.Repo.Migrations.CreatePostgresMigrationRecords do
  use Ecto.Migration

  def change do
    create table(:postgres_migration_records) do
      add :status, :string, null: false
      add :report, :map, null: false, default: %{}
      add :paused_queues, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime)
    end
  end
end
