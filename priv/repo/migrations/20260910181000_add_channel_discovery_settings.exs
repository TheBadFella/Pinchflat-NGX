defmodule Pinchflat.Repo.Migrations.AddChannelDiscoverySettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :channel_discovery_enabled, :boolean, default: false, null: false
      add :channel_discovery_mentions_enabled, :boolean, default: false, null: false
      add :channel_discovery_featured_enabled, :boolean, default: false, null: false
    end
  end
end
