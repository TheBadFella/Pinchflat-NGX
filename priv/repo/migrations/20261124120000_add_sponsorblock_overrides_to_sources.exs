defmodule Pinchflat.Repo.Migrations.AddSponsorblockOverridesToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :sponsorblock_mark_categories, {:array, :string}
      add :sponsorblock_remove_categories, {:array, :string}
    end
  end
end
