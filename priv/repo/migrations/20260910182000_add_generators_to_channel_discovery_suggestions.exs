defmodule Pinchflat.Repo.Migrations.AddGeneratorsToChannelDiscoverySuggestions do
  use Ecto.Migration

  def change do
    alter table(:channel_discovery_suggestions) do
      add :generators, :string, null: false, default: ""
    end
  end
end
