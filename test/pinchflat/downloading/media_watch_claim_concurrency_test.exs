defmodule Pinchflat.Downloading.MediaWatchClaimConcurrencyTest do
  use ExUnit.Case, async: false
  # Uses real connections and advances sequences outside the shared sandbox.
  # Run alone against a disposable database, never in the default suite.
  @moduletag :migration_schema

  import Ecto.Query
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.MediaWatchEvent, as: Event
  alias Pinchflat.Repo

  test "independent connections claim a pending first completion and event fingerprint only once" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      profile = media_profile_fixture()
      profile |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
      source = source_fixture(%{media_profile_id: profile.id})
      path = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "claim-#{Ecto.UUID.generate()}.mkv")
      item = media_item_fixture(%{source_id: source.id, media_filepath: path})
      File.write!(path, "first artifact")
      first = ~U[2026-10-01 00:00:00Z]

      item =
        item
        |> Ecto.Changeset.change(watch_download_started_at: first, watch_enrollment_pending_at: first)
        |> Repo.update!()

      try do
        results = concurrent(fn -> MediaWatch.complete_pending_download(item) end)
        assert Enum.all?(results, &match?({:ok, _}, &1))
        watch = Repo.get_by!(Watch, media_item_id: item.id)
        assert watch.started_at == first
        assert Repo.aggregate(Watch, :count, :id) == 1
        assert Repo.reload!(item).media_downloaded_at == first

        events = concurrent(fn -> MediaWatch.record_event(watch, "duration", "same-fingerprint") end)
        assert Enum.count(events, &match?({:ok, %Event{}}, &1)) == 1
        assert Enum.count(events, &(&1 == {:ok, :duplicate})) == 1
        assert Repo.aggregate(Event, :count, :id) == 1
      after
        if watch = Repo.get_by(Watch, media_item_id: item.id) do
          Repo.delete_all(from event in Event, where: event.media_watch_id == ^watch.id)
          Repo.delete!(watch)
        end

        Repo.delete!(item)
        Repo.delete!(source)
        Repo.delete!(profile)
        File.rm!(path)
      end
    end)
  end

  defp concurrent(fun) do
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> fun.())
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}
      send(pid, :go)
    end

    Enum.map(tasks, &Task.await(&1, 10_000))
  end
end
