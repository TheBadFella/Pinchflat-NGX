defmodule Pinchflat.Repo.Migrations.AddWatchPostprocessingPending do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :watch_postprocessing_pending, :boolean, null: false, default: false
    end
  end
end
