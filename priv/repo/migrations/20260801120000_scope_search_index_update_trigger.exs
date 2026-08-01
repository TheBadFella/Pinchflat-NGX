defmodule Pinchflat.Repo.Migrations.ScopeSearchIndexUpdateTrigger do
  use Ecto.Migration

  # The old trigger fired on EVERY media_items update — and during an active
  # queue almost none of those touch title/description (filepaths, sizes,
  # timestamps, last_error, culled_at, …). Each firing rebuilds the item's full
  # trigram FTS entry (thousands of postings for a long description), holding
  # the single SQLite write lock far longer than the visible UPDATE. Scoping the
  # trigger to actual title/description changes removes that write amplification.
  #
  # Both guards are needed: UPDATE OF only checks that the column was assigned,
  # not that its value changed (upserts re-assign every column), so the WHEN
  # clause does the real work. IS NOT is SQLite's null-safe inequality.
  def up do
    execute "DROP TRIGGER IF EXISTS media_items_search_index_update;"

    execute """
      CREATE TRIGGER media_items_search_index_update
      AFTER UPDATE OF title, description ON media_items
      WHEN old.title IS NOT new.title OR old.description IS NOT new.description
      BEGIN
        UPDATE media_items_search_index SET
          title = new.title,
          description = new.description
        WHERE
          rowid = old.id;
      END;
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS media_items_search_index_update;"

    execute """
      CREATE TRIGGER media_items_search_index_update AFTER UPDATE ON media_items BEGIN
        UPDATE media_items_search_index SET
          title = new.title,
          description = new.description
        WHERE
          rowid = old.id;
      END;
    """
  end
end
