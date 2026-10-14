defmodule Pinchflat.Database.SourceDescriptionMigrationPostgresTest do
  @moduledoc """
  Run in an isolated PostgreSQL database with --include migration_schema.
  These tests change the description column type and must not share a normal test run.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_only
  @moduletag :migration_schema

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  import Pinchflat.SourcesFixtures
  import Ecto.Query

  @migration {20_261_011_180_000, Pinchflat.Repo.Migrations.WidenSourceDescription}

  setup_all do
    Code.require_file("priv/repo/migrations/20261011180000_widen_source_description.exs")
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    source = source_fixture(%{description: String.duplicate("Ω", 255)})
    on_exit(fn -> Repo.delete_all(from(s in Source, where: s.id == ^source.id)) end)
    %{source: source}
  end

  test "populated rollback and reapply preserve bounded values and remove the old failure", %{source: source} do
    assert column_type() == ["text", nil]
    assert [20_261_011_180_000] = Ecto.Migrator.run(Repo, [@migration], :down, step: 1)

    try do
      assert column_type() == ["character varying", 255]
      assert source_description(source.id) == source.description

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE sources SET description = $1 WHERE id = $2", [String.duplicate("Ω", 256), source.id])
        end

      assert error.postgres.code == :string_data_right_truncation
    after
      Ecto.Migrator.run(Repo, [@migration], :up, step: 1)
    end

    assert column_type() == ["text", nil]
    value = String.duplicate("日本語 Ω 🎥", 1_000)
    Repo.query!("UPDATE sources SET description = $1 WHERE id = $2", [value, source.id])
    assert source_description(source.id) == value
  end

  test "unsafe rollback leaves the full description and migration intact", %{source: source} do
    value = String.duplicate("Ω", 256)
    source |> Ecto.Changeset.change(description: value) |> Repo.update!()

    assert_raise RuntimeError, ~r/cannot narrow source descriptions/, fn ->
      Ecto.Migrator.run(Repo, [@migration], :down, step: 1)
    end

    assert column_type() == ["text", nil]
    assert source_description(source.id) == value
    assert 20_261_011_180_000 in Ecto.Migrator.migrated_versions(Repo)
  end

  defp column_type do
    %{rows: [type]} =
      Repo.query!("""
      SELECT data_type, character_maximum_length FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'sources' AND column_name = 'description'
      """)

    type
  end

  defp source_description(id) do
    # The cast keeps the prepared result type stable across this schema-only test.
    %{rows: [[description]]} = Repo.query!("SELECT description::text FROM sources WHERE id = $1", [id])
    description
  end
end
