defmodule Pinchflat.Repo.Migrations.AddDownloadCutoffDaysToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :download_cutoff_days, :integer
    end
  end
end
