defmodule Pinchflat.Repo.Migrations.AddAvailabilityPoliciesToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :download_public_media, :boolean, default: true, null: false
      add :download_members_only_media, :boolean, default: true, null: false
    end
  end
end
