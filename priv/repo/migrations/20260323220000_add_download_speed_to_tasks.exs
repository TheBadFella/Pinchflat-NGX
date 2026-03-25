defmodule Pinchflat.Repo.Migrations.AddDownloadSpeedToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :progress_speed_bytes_per_second, :integer
    end
  end
end
