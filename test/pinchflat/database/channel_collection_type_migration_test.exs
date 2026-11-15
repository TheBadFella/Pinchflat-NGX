defmodule Pinchflat.Database.ChannelCollectionTypeMigrationTest do
  use ExUnit.Case, async: false
  @moduletag :sqlite_only

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  test "repairs channel records without changing real playlists, names, settings or relationships" do
    migration = Pinchflat.Repo.Migrations.RepairChannelCollectionTypes

    unless Code.ensure_loaded?(migration),
      do: Code.require_file("priv/repo/migrations/20261115010000_repair_channel_collection_types.exs")

    directory = Path.join(System.tmp_dir!(), "channel-repair-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    start_supervised!({FixtureRepo, database: Path.join(directory, "fixture.db")})
    on_exit(fn -> File.rm_rf!(directory) end)

    FixtureRepo.query!(
      "CREATE TABLE sources (id INTEGER PRIMARY KEY, collection_type TEXT, collection_id TEXT, original_url TEXT, custom_name TEXT, download_media INTEGER)"
    )

    FixtureRepo.query!("CREATE TABLE media_items (id INTEGER PRIMARY KEY, source_id INTEGER REFERENCES sources(id))")
    channel_id = "UCBR8-60-B28hp2BmDPdntcQ"

    urls = [
      {"https://www.youtube.com/@YouTube", channel_id, "playlist", "channel"},
      {"https://www.youtube.com/channel/#{channel_id}", channel_id, "playlist", "channel"},
      {"https://www.youtube.com/channel/#{channel_id}/videos", channel_id, "playlist", "channel"},
      {"https://www.youtube.com/user/YouTube", channel_id, "playlist", "channel"},
      {"https://www.youtube.com/c/YouTube", channel_id, "playlist", "channel"},
      {"https://www.youtube.com/@YouTube/shorts", channel_id, "playlist", "channel"},
      {"https://www.youtube.com/playlist?list=PLtest", "PLtest", "playlist", "playlist"},
      {"https://www.youtube.com/watch?v=video&list=PLtest", channel_id, "playlist", "playlist"},
      {"https://www.youtube.com/@YouTube?list=PLtest", channel_id, "playlist", "playlist"},
      {"https://example.com/@YouTube", channel_id, "playlist", "playlist"},
      {"https://www.youtube.com/channel/UCdifferent", channel_id, "playlist", "playlist"},
      {"https://www.youtube.com/@YouTube", "PLtest", "playlist", "playlist"},
      {"https://www.youtube.com/watch?v=video", "video", "video", "video"},
      {"https://www.youtube.com/@YouTube", channel_id, "channel", "channel"}
    ]

    for {{url, id, type, _expected}, index} <- Enum.with_index(urls, 1) do
      FixtureRepo.insert_all("sources", [
        %{
          id: index,
          collection_type: type,
          collection_id: id,
          original_url: url,
          custom_name: "Keep me",
          download_media: 0
        }
      ])

      FixtureRepo.insert_all("media_items", [%{id: index, source_id: index}])
    end

    version = 20_261_115_010_000

    for direction <- [:up, :down, :up] do
      assert [^version] = Ecto.Migrator.run(FixtureRepo, [{version, migration}], direction, step: 1)

      assert FixtureRepo.query!("SELECT collection_type FROM sources ORDER BY id").rows ==
               Enum.map(urls, fn {_, _, _, expected} -> [expected] end)

      assert FixtureRepo.query!("SELECT custom_name, download_media FROM sources ORDER BY id").rows ==
               List.duplicate(["Keep me", 0], length(urls))

      assert FixtureRepo.query!("SELECT source_id FROM media_items ORDER BY id").rows ==
               Enum.map(1..length(urls), &[&1])
    end
  end
end
