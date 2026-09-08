defmodule Pinchflat.Repo.Migrations.ChangeMediaItemsSearchIndexTokenizer do
  use Ecto.Migration

  def up do
    if Pinchflat.Database.postgres?(),
      do: backfill_postgres_search(),
      else: rebuild_sqlite_search()
  end

  def down do
    if Pinchflat.Database.postgres?() do
      execute "UPDATE media_items SET search_vector = NULL;"
    else
      execute "DROP TABLE media_items_search_index;"
    end
  end

  defp rebuild_sqlite_search do
    # These all need to run as part of separate `execute` blocks. Do NOT ask me why.
    execute "DROP TRIGGER IF EXISTS media_items_search_index_insert;"
    execute "DROP TRIGGER IF EXISTS media_items_search_index_update;"
    execute "DROP TRIGGER IF EXISTS media_items_search_index_delete;"
    execute "DROP TABLE IF EXISTS media_items_search_index;"

    execute """
      CREATE VIRTUAL TABLE media_items_search_index USING fts5(
        title,
        description,
        tokenize=trigram
      );
    """

    execute """
      CREATE TRIGGER media_items_search_index_insert AFTER INSERT ON media_items BEGIN
        INSERT INTO media_items_search_index(
          rowid,
          title,
          description
        )
        VALUES(
          new.id,
          new.title,
          new.description
        );
      END;
    """

    execute """
      CREATE TRIGGER media_items_search_index_update AFTER UPDATE ON media_items BEGIN
        UPDATE media_items_search_index SET
          title = new.title,
          description = new.description
        WHERE
          rowid = old.id;
      END;
    """

    execute """
      CREATE TRIGGER media_items_search_index_delete AFTER DELETE ON media_items BEGIN
        DELETE FROM media_items_search_index WHERE rowid = old.id;
      END;
    """

    # Fully re-index the media_items table
    execute """
      INSERT INTO media_items_search_index(rowid, title, description)
      SELECT id, title, description FROM media_items;
    """
  end

  defp backfill_postgres_search do
    execute """
      UPDATE media_items SET search_vector =
        setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('simple', coalesce(description, '')), 'B');
    """
  end
end
