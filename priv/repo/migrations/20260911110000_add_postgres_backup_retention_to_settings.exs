defmodule Pinchflat.Repo.Migrations.AddPostgresBackupRetentionToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :postgres_backup_retention_count, :integer, default: 7, null: false
    end
  end
end
