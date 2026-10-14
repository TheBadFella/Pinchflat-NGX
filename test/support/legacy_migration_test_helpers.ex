defmodule Pinchflat.LegacyMigrationTestHelpers do
  @moduledoc false

  alias Pinchflat.Database

  @doc """
  Installs a trigger that rejects updates to `legacy_migration_records.status`
  when the new value equals `status_value`. Used to simulate persistence failures.
  """
  def install_reject_status_update_trigger!(repo, trigger_name, status_value) do
    if Database.postgres?() do
      function_name = "#{trigger_name}_fn"

      Ecto.Adapters.SQL.query!(
        repo,
        """
        CREATE OR REPLACE FUNCTION #{function_name}() RETURNS trigger AS $$
        BEGIN
          IF NEW.status = '#{status_value}' THEN
            RAISE EXCEPTION '#{trigger_name} rejected';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """
      )

      Ecto.Adapters.SQL.query!(
        repo,
        """
        CREATE TRIGGER #{trigger_name}
        BEFORE UPDATE ON legacy_migration_records
        FOR EACH ROW
        EXECUTE FUNCTION #{function_name}();
        """
      )
    else
      Ecto.Adapters.SQL.query!(
        repo,
        """
        CREATE TEMP TRIGGER #{trigger_name} BEFORE UPDATE OF status ON legacy_migration_records
        WHEN NEW.status='#{status_value}' BEGIN SELECT RAISE(ABORT, '#{trigger_name} rejected'); END
        """
      )
    end
  end

  @doc false
  def drop_reject_status_update_trigger!(repo, trigger_name) do
    if Database.postgres?() do
      function_name = "#{trigger_name}_fn"
      Ecto.Adapters.SQL.query!(repo, "DROP TRIGGER IF EXISTS #{trigger_name} ON legacy_migration_records")
      Ecto.Adapters.SQL.query!(repo, "DROP FUNCTION IF EXISTS #{function_name}()")
    else
      Ecto.Adapters.SQL.query!(repo, "DROP TRIGGER #{trigger_name}")
    end
  end
end
