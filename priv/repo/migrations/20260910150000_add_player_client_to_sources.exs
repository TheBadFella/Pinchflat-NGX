defmodule Pinchflat.Repo.Migrations.AddPlayerClientToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :player_client, :string
    end
  end
end
