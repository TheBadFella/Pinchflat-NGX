defmodule Pinchflat.Repo.Migrations.AddRetentionPeriodToMediaProfiles do
  use Ecto.Migration

  def change do
    alter table(:media_profiles) do
      add :retention_period_days, :integer
    end
  end
end
