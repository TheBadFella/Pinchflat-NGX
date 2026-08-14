defmodule Pinchflat.Repo.Migrations.AddIndexCutoffDateToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :index_cutoff_date, :date
    end
  end
end
