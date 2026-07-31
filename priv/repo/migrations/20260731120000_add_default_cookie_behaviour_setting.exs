defmodule Pinchflat.Repo.Migrations.AddDefaultCookieBehaviourSetting do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # The cookie behaviour pre-selected when adding a new source:
      # "disabled" | "when_needed" | "all_operations". Matches the values of
      # Source.cookie_behaviour (stored as a string here since Settings has no enum)
      add :default_cookie_behaviour, :string, default: "disabled", null: false
    end
  end
end
