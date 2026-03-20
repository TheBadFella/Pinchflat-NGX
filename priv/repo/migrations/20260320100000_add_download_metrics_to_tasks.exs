defmodule Pinchflat.Repo.Migrations.AddDownloadMetricsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :progress_downloaded_bytes, :integer
      add :progress_total_bytes, :integer
      add :progress_eta_seconds, :integer
    end
  end
end
