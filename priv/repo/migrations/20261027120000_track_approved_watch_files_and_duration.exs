defmodule Pinchflat.Repo.Migrations.TrackApprovedWatchFilesAndDuration do
  use Ecto.Migration

  def change do
    alter table(:media_watches) do
      add :confirmed_upstream_duration_seconds, :integer
      add :approved_active_files, :map
    end

    execute(
      "UPDATE media_watches SET confirmed_upstream_duration_seconds = current_upstream_duration_seconds WHERE confirmed_change_at IS NOT NULL",
      "UPDATE media_watches SET confirmed_upstream_duration_seconds = NULL"
    )
  end
end
