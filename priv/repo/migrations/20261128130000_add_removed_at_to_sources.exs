defmodule Pinchflat.Repo.Migrations.AddRemovedAtToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :removed_at, :utc_datetime
      add :removed_reason, :string
    end
  end
end
