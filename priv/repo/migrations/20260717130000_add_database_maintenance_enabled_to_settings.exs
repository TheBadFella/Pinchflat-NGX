defmodule Pinchflat.Repo.Migrations.AddDatabaseMaintenanceEnabledToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Opt-in while the feature matures — intended to become opt-out later
      add :database_maintenance_enabled, :boolean, default: false
    end
  end
end
