defmodule Pinchflat.Database.MediaSizeMigrationPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres_only
  @moduletag :migration_schema

  import Ecto.Query

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo

  @version 20_261_101_190_000
  @migration {@version, Pinchflat.Repo.Migrations.WidenMediaSizeBytes}

  setup_all do
    Code.require_file("priv/repo/migrations/20261101190000_widen_media_size_bytes.exs")
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    item = Pinchflat.MediaFixtures.media_item_fixture(%{media_size_bytes: 77})
    on_exit(fn -> Repo.delete_all(from(mi in MediaItem, where: mi.id == ^item.id)) end)
    %{item: item}
  end

  test "upgrades a populated integer column without losing sizes", %{item: item} do
    assert [@version] = Ecto.Migrator.run(Repo, [@migration], :down, step: 1)

    try do
      assert column_type() == "integer"

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE media_items SET media_size_bytes = 2147483648 WHERE id = $1", [item.id])
      end
    after
      Ecto.Migrator.run(Repo, [@migration], :up, step: 1)
    end

    assert column_type() == "bigint"
    assert size(item.id) == "77"
    Repo.query!("UPDATE media_items SET media_size_bytes = 3650722202 WHERE id = $1", [item.id])
    assert size(item.id) == "3650722202"
  end

  test "unsafe rollback retains the size and migration", %{item: item} do
    Repo.query!("UPDATE media_items SET media_size_bytes = 3650722202 WHERE id = $1", [item.id])

    assert_raise RuntimeError, ~r/cannot narrow media sizes/, fn ->
      Ecto.Migrator.run(Repo, [@migration], :down, step: 1)
    end

    assert column_type() == "bigint"
    assert size(item.id) == "3650722202"
    assert @version in Ecto.Migrator.migrated_versions(Repo)
  end

  defp column_type do
    [[type]] =
      Repo.query!("""
      SELECT data_type FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'media_items' AND column_name = 'media_size_bytes'
      """).rows

    type
  end

  # A cast avoids cached Postgrex result types across the schema change.
  defp size(id),
    do: Repo.query!("SELECT media_size_bytes::text FROM media_items WHERE id = $1", [id]).rows |> hd() |> hd()
end
