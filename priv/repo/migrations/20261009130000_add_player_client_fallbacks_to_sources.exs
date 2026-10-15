defmodule Pinchflat.Repo.Migrations.AddPlayerClientFallbacksToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :player_client_fallbacks, {:array, :string}, default: []
    end
  end
end
