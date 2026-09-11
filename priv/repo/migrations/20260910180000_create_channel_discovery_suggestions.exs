defmodule Pinchflat.Repo.Migrations.CreateChannelDiscoverySuggestions do
  use Ecto.Migration

  def change do
    create table(:channel_discovery_suggestions) do
      add :external_channel_id, :string, null: false
      add :canonical_url, :string, null: false
      add :channel_name, :string, null: false
      add :artwork_url, :string
      add :evidence, :string, null: false, default: ""
      add :score, :integer, null: false, default: 0
      add :validated_at, :utc_datetime
      add :state, :string, null: false, default: "validated"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_discovery_suggestions, [:external_channel_id])
    create index(:channel_discovery_suggestions, [:state, :score])
  end
end
