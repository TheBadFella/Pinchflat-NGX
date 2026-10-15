defmodule Pinchflat.Repo.Migrations.AddMediaItemsQueryOptimizationIndexes do
  use Ecto.Migration

  def change do
    create index(:media_items, [:source_id, :uploaded_at])
    create index(:media_items, [:error_type], where: "error_type IS NOT NULL")
  end
end
