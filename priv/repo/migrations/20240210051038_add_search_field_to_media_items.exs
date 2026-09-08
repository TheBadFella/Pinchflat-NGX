defmodule Pinchflat.Repo.Migrations.AddSearchFieldToMediaItems do
  use Ecto.Migration

  def up do
    if Pinchflat.Database.postgres?(), do: create_postgres_search(), else: create_sqlite_search()
  end

  def down do
    if Pinchflat.Database.postgres?() do
      execute "DROP TRIGGER IF EXISTS media_items_search_vector_update ON media_items;"
      execute "DROP FUNCTION IF EXISTS media_items_search_vector_trigger();"
      execute "DROP INDEX IF EXISTS media_items_search_vector_idx;"

      alter table(:media_items) do
        remove :search_vector
      end
    else
      execute "DROP TABLE media_items_search_index;"
    end
  end

  defp create_sqlite_search do
    # These all need to run as part of separate `execute` blocks. Do NOT ask me why.
    execute """
      CREATE VIRTUAL TABLE media_items_search_index USING fts5(
        title,
        description,
        tokenize=porter
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
  end

  defp create_postgres_search do
    alter table(:media_items) do
      add :search_vector, :tsvector
    end

    execute "CREATE INDEX media_items_search_vector_idx ON media_items USING GIN(search_vector);"

    execute """
      CREATE OR REPLACE FUNCTION media_items_search_vector_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector :=
          setweight(to_tsvector('simple', coalesce(NEW.title, '')), 'A') ||
          setweight(to_tsvector('simple', coalesce(NEW.description, '')), 'B');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    """

    execute """
      CREATE TRIGGER media_items_search_vector_update
      BEFORE INSERT OR UPDATE OF title, description ON media_items
      FOR EACH ROW EXECUTE FUNCTION media_items_search_vector_trigger();
    """
  end
end
