defmodule Pinchflat.Repo.Migrations.AddMediaItemsPendingIndexes do
  use Ecto.Migration

  def change do
    # Pending media has no media_filepath yet. Both pending_media_items_query/1
    # and the dashboard pending-count subqueries filter on source_id and
    # `media_filepath IS NULL` (the latter also groups by source_id), so keep
    # the index limited to pending rows and ordered by id for per-source lists.
    create index(:media_items, [:source_id, :id],
             where: "media_filepath IS NULL",
             name: "media_items_pending_source_index"
           )
  end
end
