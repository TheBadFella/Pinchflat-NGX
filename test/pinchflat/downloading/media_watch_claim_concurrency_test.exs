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
  alias Pinchflat.MediaWatch.OriginalArchive
  alias Pinchflat.MediaWatch.ReplacementIntent
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

  test "recovery on another connection never restores a live replacement" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      profile = media_profile_fixture()
      profile |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
      source = source_fixture(%{media_profile_id: profile.id})
      path = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "race-#{Ecto.UUID.generate()}.mkv")
      item = media_item_fixture(%{source_id: source.id, media_filepath: path})
      File.write!(path, "first artifact")
      {:ok, watch} = MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))
      {:ok, _} = MediaWatch.archive_original(watch, Repo.preload(item, :metadata))
      {:ok, lease} = MediaWatch.claim_lease(item.id, "replace")
      operation_id = Ecto.UUID.generate()
      hash = Base.encode16(:crypto.hash(:sha256, "first artifact"), case: :lower)

      try do
        {:ok, _} = ReplacementIntent.publish(watch.id, %{
          "operation_id" => operation_id,
          "phase" => "transferring",
          "active" => [%{"role" => "media", "path" => path, "sha256" => hash, "size" => 14}],
          "staged" => []
        })

        assert [%{action: :needs_recovery}] = Enum.filter(MediaWatch.recover_pending(), &(&1.watch_id == watch.id))
        assert ReplacementIntent.pending?(watch.id)
        assert File.read!(path) == "first artifact"

        parent = self()

        writer = Task.async(fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(w in Watch, where: w.id == ^watch.id), set: [updated_at: DateTime.utc_now()])
            File.write!(path, "replacement artifact")
            send(parent, :writer_reserved)
            receive do: (:finish -> :ok)
            Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
              set: [operation_id: operation_id, lease_owner: nil, lease_expires_at: nil]
            )
          end)
        end)

        assert_receive :writer_reserved
        recovery = Task.async(fn -> MediaWatch.recover_pending() end)
        send(writer.pid, :finish)
        assert {:ok, _} = Task.await(writer, 10_000)
        assert [%{action: :commit_confirmed}] =
                 Enum.filter(Task.await(recovery, 10_000), &(&1.watch_id == watch.id))
        assert File.read!(path) == "replacement artifact"
        refute ReplacementIntent.pending?(watch.id)
      after
        _ = ReplacementIntent.clear(watch.id, operation_id)
        Repo.delete_all(from event in Event, where: event.media_watch_id == ^watch.id)
        Repo.delete!(Repo.get!(Watch, watch.id))
        Repo.delete!(item)
        Repo.delete!(source)
        Repo.delete!(profile)
        File.rm(path)
        File.rm_rf(OriginalArchive.root())
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
