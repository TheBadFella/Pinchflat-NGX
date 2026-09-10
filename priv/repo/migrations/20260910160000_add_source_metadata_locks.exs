defmodule Pinchflat.Repo.Migrations.AddSourceMetadataLocks do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :custom_name_locked, :boolean, default: false, null: false
      add :description_locked, :boolean, default: false, null: false
    end
  end
end
