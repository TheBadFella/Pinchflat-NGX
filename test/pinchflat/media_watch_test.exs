defmodule Pinchflat.MediaWatchTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.MediaWatchEvent, as: Event
  alias Pinchflat.Profiles
  alias Pinchflat.Sources

  defp enabled_item(days, override \\ nil) do
    profile = media_profile_fixture()
    profile |> Ecto.Changeset.change(watch_window_days: days) |> Repo.update!()
    source = source_fixture(%{media_profile_id: profile.id})
    source |> Ecto.Changeset.change(watch_window_days: override) |> Repo.update!()
    {media_item_fixture(%{source_id: source.id}), Repo.reload!(source) |> Repo.preload(:media_profile)}
  end

  test "policy defaults, inheritance, explicit zero and positive windows are allowed" do
    {item, source} = enabled_item(14)
    assert MediaWatch.effective_watch_window_days(source) == 14
    assert Repo.get!(Pinchflat.Profiles.MediaProfile, source.media_profile_id).watch_window_days == 14
    assert Sources.Source.effective_watch_window_days(%{source | watch_window_days: 0}) == 0

    assert {:ok, updated_source} = Sources.update_source(source, %{watch_window_days: 4})
    assert updated_source.watch_window_days == 4

    assert {:ok, updated_profile} = Profiles.update_media_profile(source.media_profile, %{watch_window_days: 7})
    assert updated_profile.watch_window_days == 7

    assert {:error, changeset} = Sources.update_source(source, %{watch_window_days: 366})
    assert errors_on(changeset).watch_window_days
    assert {:error, changeset} = Profiles.update_media_profile(source.media_profile, %{watch_window_days: -1})
    assert errors_on(changeset).watch_window_days
    assert Repo.reload!(item).media_downloaded_at == nil
  end

  test "enrollment and event fingerprints are immutable and idempotent" do
    {item, source} = enabled_item(14)
    path = Path.join(Application.get_env(:pinchflat, :media_directory), "watch-original-#{item.id}.mkv")
    File.write!(path, "original")
    {:ok, item} = Pinchflat.Media.update_media_item(item, %{media_filepath: path})
    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, source)
    assert watch.baseline_upstream_duration_seconds == nil
    assert DateTime.diff(watch.ends_at, watch.started_at) == 14 * 86_400
    assert {:ok, :already_enrolled} = MediaWatch.enroll_on_first_completion(item, source, upstream_duration_seconds: 90)
    assert Repo.get!(Watch, watch.id).baseline_upstream_duration_seconds == nil
    assert {:ok, event} = MediaWatch.record_event(watch, "edited", "same", %{new_value: "edited"})
    assert {:ok, :duplicate} = MediaWatch.record_event(watch, "edited", "same", %{new_value: "other"})
    assert Repo.get!(Event, event.id).new_value == "edited"
    assert Repo.aggregate(Event, :count) == 1
    assert {:error, %Ecto.Changeset{}} = MediaWatch.record_event(watch, nil, "bad")
  end

  test "two completion claims keep one immutable watch and one first-success timestamp" do
    {item, _source} = enabled_item(14)
    path = Path.join(Application.get_env(:pinchflat, :media_directory), "watch-race-#{item.id}.mkv")
    first = ~U[2026-01-01 00:00:00Z]

    {:ok, item} =
      Pinchflat.Media.update_media_item(item, %{
        media_filepath: path,
        watch_download_started_at: first,
        watch_enrollment_pending_at: first
      })

    :ok = Pinchflat.MediaWatchFixtures.completed_first_artifact(item, path, first)

    tasks = for _ <- 1..2, do: Task.async(fn -> MediaWatch.complete_pending_download(item) end)
    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await(&1, 5_000))
    assert first.media_downloaded_at == second.media_downloaded_at
    assert Repo.aggregate(Watch, :count) == 1
    assert Repo.reload!(item).watch_enrollment_pending_at == nil
    assert Repo.reload!(item).watch_download_started_at == nil
    assert :ok = Pinchflat.Downloading.FirstArtifact.clear(item)
  end

  test "SQLite migrated constraints reject invalid raw policy and watch state on insert and update" do
    if Pinchflat.Database.postgres?() do
      # PostgreSQL uses named CHECK constraints; exercise independently in the PG job.
      :ok
    else
      {item, source} = enabled_item(0)

      assert {:error, _} =
               Repo.query("UPDATE media_profiles SET watch_window_days = -1 WHERE id = ?", [source.media_profile_id])

      assert {:error, _} =
               Repo.query("UPDATE media_profiles SET watch_window_days = NULL WHERE id = ?", [source.media_profile_id])

      assert {:error, _} = Repo.query("UPDATE sources SET watch_window_days = 366 WHERE id = ?", [source.id])

      assert {:error, _} =
               Repo.query(
                 "INSERT INTO media_watches (media_item_uuid, media_id, started_at, ends_at, archive_state, confirmed_state) VALUES (?, ?, ?, ?, ?, ?)",
                 [item.uuid, item.media_id, "2026-01-01", "2026-01-02", "illegal", "unchanged"]
               )

      assert {:error, _} =
               Repo.query(
                 "INSERT INTO media_watches (media_item_uuid, media_id, started_at, ends_at, archive_state, confirmed_state) VALUES (?, ?, ?, ?, ?, ?)",
                 [item.uuid, item.media_id, "2026-01-01", "2026-01-02", "none", "illegal"]
               )

      path = Path.join(Application.get_env(:pinchflat, :media_directory), "watch-constraint-#{item.id}")
      File.write!(path, "original")
      {:ok, item} = Pinchflat.Media.update_media_item(item, %{media_filepath: path})
      {:ok, watch} = MediaWatch.enroll_on_first_completion(item, source |> Map.put(:watch_window_days, 1))
      assert {:error, _} = Repo.query("UPDATE media_watches SET archive_state = 'illegal' WHERE id = ?", [watch.id])
      assert {:error, _} = Repo.query("UPDATE media_watches SET confirmed_state = 'illegal' WHERE id = ?", [watch.id])
      assert Repo.reload!(watch).archive_state == "none"
    end
  end
end
