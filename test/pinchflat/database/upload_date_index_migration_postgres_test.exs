defmodule Pinchflat.Database.UploadDateIndexMigrationPostgresTest do
  @moduledoc """
  PostgreSQL schema migration coverage.

  These tests are excluded from the normal suite because they change the schema.
  Run them with `docker/docker-compose.postgres.migrations.yml`, which provides
  a separate PostgreSQL database.
  """

  use ExUnit.Case, async: false

  @moduletag :postgres_only
  @moduletag :migration_schema
  @index_migration 20_240_529_000_015

  alias Pinchflat.Repo

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    :ok
  end

  test "rollback restores the original index before the column rename" do
    assert Ecto.Migrator.run(Repo, migrations_path(), :down, to: @index_migration) != []

    on_exit(fn ->
      assert Ecto.Migrator.run(Repo, migrations_path(), :up, all: true) != []
    end)

    assert %{rows: [["media_items_upload_date_index", index_definition]]} =
             Repo.query!("""
             SELECT indexname, indexdef
             FROM pg_indexes
             WHERE schemaname = current_schema()
               AND tablename = 'media_items'
               AND indexname IN ('media_items_upload_date_index', 'media_items_uploaded_at_index')
             ORDER BY indexname
             """)

    assert index_definition =~ "(uploaded_at)"
  end

  defp migrations_path, do: Path.join(File.cwd!(), "priv/repo/migrations")
end
