defmodule Pinchflat.Repo.Migrations.TrackObservedWatchVisibility do
  use Ecto.Migration

  def change do
    alter table(:media_watches) do
      add :observed_visibility, :string
      remove :current_reason, :string
    end

    execute(
      "UPDATE media_watches SET observed_visibility = CASE WHEN confirmed_state = 'suspected' AND suspected_kind IN ('unavailable', 'visibility', 'restored') THEN suspected_value ELSE current_visibility END",
      "UPDATE media_watches SET observed_visibility = NULL"
    )
  end
end
