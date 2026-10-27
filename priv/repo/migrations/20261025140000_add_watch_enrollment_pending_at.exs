defmodule Pinchflat.Repo.Migrations.AddWatchEnrollmentPendingAt do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :watch_download_started_at, :utc_datetime
      add :watch_enrollment_pending_at, :utc_datetime
    end
  end
end
