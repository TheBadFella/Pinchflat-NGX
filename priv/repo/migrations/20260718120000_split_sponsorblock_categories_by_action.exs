defmodule Pinchflat.Repo.Migrations.SplitSponsorblockCategoriesByAction do
  use Ecto.Migration

  def up do
    alter table(:media_profiles) do
      add :sponsorblock_mark_categories, {:array, :string}, default: []
      add :sponsorblock_remove_categories, {:array, :string}, default: []
    end

    execute """
    UPDATE media_profiles
    SET sponsorblock_mark_categories = sponsorblock_categories
    WHERE sponsorblock_behaviour = 'mark' AND sponsorblock_categories IS NOT NULL
    """

    execute """
    UPDATE media_profiles
    SET sponsorblock_remove_categories = sponsorblock_categories
    WHERE sponsorblock_behaviour = 'remove' AND sponsorblock_categories IS NOT NULL
    """

    alter table(:media_profiles) do
      remove :sponsorblock_behaviour
      remove :sponsorblock_categories
    end
  end

  def down do
    alter table(:media_profiles) do
      add :sponsorblock_behaviour, :string, default: "disabled"
      add :sponsorblock_categories, {:array, :string}, default: []
    end

    # Remove takes precedence over mark when collapsing back to a single behaviour
    execute """
    UPDATE media_profiles
    SET sponsorblock_behaviour = 'mark', sponsorblock_categories = sponsorblock_mark_categories
    WHERE json_array_length(sponsorblock_mark_categories) > 0
    """

    execute """
    UPDATE media_profiles
    SET sponsorblock_behaviour = 'remove', sponsorblock_categories = sponsorblock_remove_categories
    WHERE json_array_length(sponsorblock_remove_categories) > 0
    """

    alter table(:media_profiles) do
      remove :sponsorblock_mark_categories
      remove :sponsorblock_remove_categories
    end
  end
end
