defmodule Pinchflat.Database.ChannelDiscoveryMigrationPostgresTest do
  @moduledoc """
  PostgreSQL schema migration coverage.

  These tests are excluded from the normal suite because they change table column
  types. Run them with `docker/docker-compose.postgres.migrations.yml`, which
  provides a separate PostgreSQL database:

      docker compose -f docker/docker-compose.postgres.migrations.yml run --rm phx mix test --include migration_schema test/pinchflat/database/channel_discovery_migration_postgres_test.exs test/pinchflat/database/upload_date_index_migration_postgres_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :postgres_only
  @moduletag :migration_schema

  alias Pinchflat.Discovery.Suggestion
  alias Pinchflat.Repo

  import Ecto.Query

  @text_columns ~w(canonical_url artwork_url evidence generators)
  @external_prefix "migration-test-"
  @channel_discovery_migration {
    20_260_911_100_000,
    Pinchflat.Repo.Migrations.WidenChannelDiscoveryTextColumns
  }

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    :ok
  end

  setup do
    cleanup()

    on_exit(&cleanup/0)

    :ok
  end

  test "rollback refuses to narrow values that exceed the original varchar limit" do
    insert_suggestion(%{
      external_channel_id: @external_prefix <> "oversized",
      canonical_url: String.duplicate("u", 256)
    })

    assert_raise RuntimeError, ~r/exceed the original varchar\(255\) limit/, fn ->
      migrate_down()
    end

    assert column_types() == expected_text_types()
  end

  test "rollback and reapply preserve bounded values and restore the original types" do
    values = %{
      external_channel_id: @external_prefix <> "bounded",
      canonical_url: String.duplicate("u", 255),
      artwork_url: String.duplicate("a", 255),
      evidence: String.duplicate("e", 255),
      generators: String.duplicate("g", 255)
    }

    suggestion = insert_suggestion(values)

    migrate_down()
    assert column_types() == expected_varchar_types()

    persisted = Repo.get!(Suggestion, suggestion.id)
    assert Map.take(persisted, Map.keys(values)) == values

    migrate_up()
    assert column_types() == expected_text_types()
  end

  defp migrate_down do
    assert [20_260_911_100_000] = Ecto.Migrator.run(Repo, [@channel_discovery_migration], :down, step: 1)
  end

  defp migrate_up do
    assert [20_260_911_100_000] = Ecto.Migrator.run(Repo, [@channel_discovery_migration], :up, step: 1)
  end

  defp insert_suggestion(attrs) do
    attrs =
      Map.merge(
        %{
          external_channel_id: "UC" <> String.duplicate("b", 22),
          canonical_url: "https://www.youtube.com/channel/UC" <> String.duplicate("b", 22),
          channel_name: "Migration test channel",
          artwork_url: nil,
          evidence: "",
          generators: ""
        },
        attrs
      )

    %Suggestion{}
    |> Suggestion.changeset(attrs)
    |> Repo.insert!()
  end

  defp column_types do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type, character_maximum_length
      FROM information_schema.columns
      WHERE table_name = 'channel_discovery_suggestions'
        AND column_name IN ('canonical_url', 'artwork_url', 'evidence', 'generators')
      ORDER BY column_name
      """)

    Map.new(rows, fn [column, data_type, length] -> {column, {data_type, length}} end)
  end

  defp expected_text_types do
    Map.new(@text_columns, &{&1, {"text", nil}})
  end

  defp expected_varchar_types do
    Map.new(@text_columns, &{&1, {"character varying", 255}})
  end

  defp cleanup do
    Repo.delete_all(
      from suggestion in Suggestion, where: like(suggestion.external_channel_id, ^(@external_prefix <> "%"))
    )
  end
end
