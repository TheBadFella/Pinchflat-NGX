defmodule Pinchflat.Database.LibraryTextMigrationPostgresTest do
  @moduledoc "Isolated PostgreSQL schema test; run with --include migration_schema."
  use ExUnit.Case, async: false
  @moduletag :postgres_only
  @moduletag :migration_schema
  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures
  alias Pinchflat.Repo
  @migration {20_261_011_200_000, Pinchflat.Repo.Migrations.WidenLibraryTextFields}

  setup_all do
    Code.require_file("priv/repo/migrations/20261011200000_widen_library_text_fields.exs")
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "unsafe rollback preserves values, all types and the exact search trigger" do
    source = source_fixture(%{custom_name: String.duplicate("Ω", 400)})
    before = trigger()

    assert_raise RuntimeError, ~r/cannot narrow library text fields/, fn ->
      Ecto.Migrator.run(Repo, [@migration], :down, step: 1)
    end

    assert trigger() == before
    assert description_type("sources", "custom_name") == "text"
    assert %{rows: [[value]]} = Repo.query!("SELECT custom_name::text FROM sources WHERE id = $1", [source.id])
    assert value == source.custom_name
    Repo.query!("DELETE FROM sources WHERE id = $1", [source.id])
  end

  test "bounded rollback and populated reapply preserve search behavior and row identity" do
    source = source_fixture(%{custom_name: "Bounded owned name"})
    contract = contract_snapshot()
    before = trigger()
    assert [20_261_011_200_000] = Ecto.Migrator.run(Repo, [@migration], :down, step: 1)

    try do
      assert description_type("sources", "custom_name") == "character varying"
      assert trigger() == before
      assert contract_snapshot() == contract

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE sources SET custom_name = $1 WHERE id = $2", [String.duplicate("a", 256), source.id])
        end

      assert error.postgres.code == :string_data_right_truncation
    after
      Ecto.Migrator.run(Repo, [@migration], :up, step: 1)
    end

    assert description_type("sources", "custom_name") == "text"
    assert description_type("media_items", "title") == "text"
    assert trigger() == before
    assert contract_snapshot() == contract

    assert %{rows: [["Bounded owned name"]]} =
             Repo.query!("SELECT custom_name::text FROM sources WHERE id = $1", [source.id])

    Repo.query!("DELETE FROM sources WHERE id = $1", [source.id])
  end

  test "oversized nested subtitle rollback refuses atomically" do
    item = media_item_fixture(%{subtitle_filepaths: [["en", String.duplicate("x", 300)]]})
    before = trigger()

    assert_raise RuntimeError, ~r/cannot narrow subtitle paths/, fn ->
      Ecto.Migrator.run(Repo, [@migration], :down, step: 1)
    end

    assert description_type("sources", "custom_name") == "text"
    assert trigger() == before
    assert Repo.reload!(item).subtitle_filepaths == item.subtitle_filepaths
    Repo.delete!(item)
    Repo.delete!(Repo.get!(Pinchflat.Sources.Source, item.source_id))
  end

  test "all 33 scalar columns and subtitle elements have effective text capacity" do
    columns = [
      media_profiles: ~w(name output_path_template sub_langs audio_track),
      sources:
        ~w(custom_name collection_name original_url series_directory nfo_filepath poster_filepath fanart_filepath banner_filepath output_path_template_override title_filter_regex),
      media_items:
        ~w(title original_url media_filepath thumbnail_filepath metadata_filepath nfo_filepath predicted_media_filepath unavailable_reason),
      source_metadata: ~w(metadata_filepath fanart_filepath poster_filepath banner_filepath),
      media_metadata: ~w(metadata_filepath thumbnail_filepath),
      settings: ~w(apprise_server external_base_url youtube_api_key),
      settings_backup: ~w(value),
      channel_discovery_suggestions: ~w(channel_name)
    ]

    assert Enum.sum(Enum.map(columns, fn {_, fields} -> length(fields) end)) == 33

    for {table, fields} <- columns, field <- fields do
      assert description_type(to_string(table), field) == "text", "#{table}.#{field}"
    end

    assert %{rows: [["_text"]]} =
             Repo.query!(
               "SELECT udt_name FROM information_schema.columns WHERE table_name = 'media_items' AND column_name = 'subtitle_filepaths'"
             )
  end

  defp contract_snapshot do
    tables =
      "'media_profiles','sources','media_items','source_metadata','media_metadata','settings','settings_backup','channel_discovery_suggestions'"

    columns =
      Repo.query!(
        "SELECT table_name,column_name,is_nullable,column_default FROM information_schema.columns WHERE table_schema='public' AND table_name IN (#{tables}) ORDER BY table_name,ordinal_position"
      ).rows

    indexes =
      Repo.query!(
        "SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' AND tablename IN (#{tables}) ORDER BY tablename,indexname"
      ).rows

    constraints =
      Repo.query!(
        "SELECT table_name,constraint_name,constraint_type FROM information_schema.table_constraints WHERE table_schema='public' AND table_name IN (#{tables}) ORDER BY table_name,constraint_name"
      ).rows

    indexes =
      Enum.map(indexes, fn [table, name, definition] ->
        # PostgreSQL adds harmless text/varchar casts when rebuilding expression indexes.
        normalized = definition |> String.replace(~r/::(?:character varying|text)/, "") |> String.replace(~r/[()]/, "")
        [table, name, normalized]
      end)

    %{columns: columns, indexes: indexes, constraints: constraints}
  end

  defp trigger do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid = 'media_items'::regclass AND tgname = 'media_items_search_vector_update'"
      )

    definition
  end

  defp description_type(table, column) do
    %{rows: [[type]]} =
      Repo.query!(
        "SELECT data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    type
  end
end
