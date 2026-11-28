defmodule Pinchflat.Repo.Migrations.CreateDeletionEvents do
  use Ecto.Migration

  def change do
    # Snapshots, not references: the deleted source or files are usually gone.
    create table(:deletion_events) do
      add :kind, :string, null: false
      add :reason, :string, null: false
      add :source_id, :integer
      add :source_name, :string
      add :source_url, :string
      add :collection_type, :string
      add :media_item_id, :integer
      add :media_id, :string
      add :media_title, :string
      add :item_count, :integer
      add :files_deleted, :boolean, default: false, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:deletion_events, [:inserted_at])
  end
end
