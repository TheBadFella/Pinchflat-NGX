defmodule Pinchflat.Repo.Migrations.AddProgressFieldsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :progress_percent, :float
      add :progress_status, :string
      add :progress_updated_at, :utc_datetime
    end
  end
end
