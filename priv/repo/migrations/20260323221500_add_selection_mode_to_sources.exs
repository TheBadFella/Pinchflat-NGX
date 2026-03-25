defmodule Pinchflat.Repo.Migrations.AddSelectionModeToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :selection_mode, :string, null: false, default: "all"
    end
  end
end
