defmodule Pinchflat.Database.DiscoveryAcceptedRestoreMigrationTest do
  use ExUnit.Case, async: false
  @moduletag :sqlite_only

  defmodule FixtureRepo do
    use Ecto.Repo, otp_app: :pinchflat, adapter: Ecto.Adapters.SQLite3
  end

  test "restores accepted suggestions that never became a channel source" do
    migration = Pinchflat.Repo.Migrations.RestoreUnsavedAcceptedDiscoverySuggestions

    unless Code.ensure_loaded?(migration),
      do: Code.require_file("priv/repo/migrations/20261126120000_restore_unsaved_accepted_discovery_suggestions.exs")

    directory = Path.join(System.tmp_dir!(), "discovery-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    start_supervised!({FixtureRepo, database: Path.join(directory, "fixture.db")})
    on_exit(fn -> File.rm_rf!(directory) end)

    FixtureRepo.query!("CREATE TABLE sources (id INTEGER PRIMARY KEY, collection_type TEXT, collection_id TEXT)")

    FixtureRepo.query!(
      "CREATE TABLE channel_discovery_suggestions (id INTEGER PRIMARY KEY, external_channel_id TEXT, state TEXT)"
    )

    FixtureRepo.insert_all("sources", [
      %{id: 1, collection_type: "channel", collection_id: "UCsaved"},
      %{id: 2, collection_type: "playlist", collection_id: "UCplaylistonly"},
      %{id: 3, collection_type: "channel", collection_id: nil}
    ])

    FixtureRepo.insert_all("channel_discovery_suggestions", [
      %{id: 1, external_channel_id: "UCsaved", state: "accepted"},
      %{id: 2, external_channel_id: "UCabandoned", state: "accepted"},
      %{id: 3, external_channel_id: "UCplaylistonly", state: "accepted"},
      %{id: 4, external_channel_id: "UCdismissed", state: "dismissed"},
      %{id: 5, external_channel_id: "UCvisible", state: "validated"}
    ])

    version = 20_261_126_120_000
    assert [^version] = Ecto.Migrator.run(FixtureRepo, [{version, migration}], :up, step: 1)

    assert FixtureRepo.query!("SELECT state FROM channel_discovery_suggestions ORDER BY id").rows ==
             [["accepted"], ["validated"], ["validated"], ["dismissed"], ["validated"]]
  end
end
