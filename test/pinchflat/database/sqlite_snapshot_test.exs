defmodule Pinchflat.Database.SqliteSnapshotTest do
  use Pinchflat.DataCase
  @moduletag :sqlite_only

  alias Pinchflat.Database.SqliteSnapshot

  test "the transfer validator accepts the schema created by the actual SQLite migrations" do
    database = Application.fetch_env!(:pinchflat, Pinchflat.Repo)[:database]

    assert :ok =
             SqliteSnapshot.with_database(database, fn db ->
               assert [["share_tokens"]] =
                        SqliteSnapshot.query!(db, "SELECT name FROM sqlite_master WHERE name='share_tokens'")

               SqliteSnapshot.validate!(db)
             end)
  end
end
