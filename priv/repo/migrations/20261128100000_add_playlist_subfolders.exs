defmodule Pinchflat.Repo.Migrations.AddPlaylistSubfolders do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :playlist_subfolders, :boolean, default: false, null: false
      add :playlist_files, :boolean, default: false, null: false
    end

    create table(:playlist_memberships) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :media_id, :string, null: false
      add :playlist_id, :string, null: false
      add :playlist_title, :string, null: false
      add :position, :integer, null: false
      add :entry_index, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:playlist_memberships, [:source_id, :media_id, :playlist_id])
  end
end
