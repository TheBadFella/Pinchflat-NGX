defmodule Pinchflat.Database.WatchPolicyPostgresTest do
  use Pinchflat.DataCase
  @moduletag :postgres_only

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaWatch
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Sources.Source

  defp rejected!(sql, params) do
    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> Repo.query!(sql, params) end, mode: :savepoint)
    end
  end

  test "migrated PostgreSQL constraints reject invalid raw policies and states" do
    source = source_fixture()
    item = media_item_fixture(%{source_id: source.id})
    profile = Repo.get!(MediaProfile, source.media_profile_id)
    assert profile.watch_window_days == 0
    assert source.watch_window_days == nil
    rejected!("UPDATE media_profiles SET watch_window_days = -1 WHERE id = $1", [profile.id])
    rejected!("UPDATE media_profiles SET watch_window_days = 366 WHERE id = $1", [profile.id])
    rejected!("UPDATE media_profiles SET watch_window_days = NULL WHERE id = $1", [profile.id])
    rejected!("UPDATE sources SET watch_window_days = -1 WHERE id = $1", [source.id])
    rejected!("UPDATE sources SET watch_window_days = 366 WHERE id = $1", [source.id])

    path = Path.join(Application.get_env(:pinchflat, :media_directory), "watch-postgres-#{item.id}")
    File.write!(path, "original")
    {:ok, item} = Pinchflat.Media.update_media_item(item, %{media_filepath: path})
    {:ok, watch} = MediaWatch.enroll_on_first_completion(item, %{source | watch_window_days: 1})
    rejected!("UPDATE media_watches SET archive_state = 'illegal' WHERE id = $1", [watch.id])
    rejected!("UPDATE media_watches SET confirmed_state = 'illegal' WHERE id = $1", [watch.id])

    rejected!(
      "INSERT INTO media_watches (media_item_uuid, media_id, started_at, ends_at, archive_state, confirmed_state) VALUES ($1, $2, now(), now(), $3, 'unchanged')",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), "invalid-archive", "illegal"]
    )

    rejected!(
      "INSERT INTO media_watches (media_item_uuid, media_id, started_at, ends_at, archive_state, confirmed_state) VALUES ($1, $2, now(), now(), 'none', $3)",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), "invalid-confirmed", "illegal"]
    )

    assert Repo.get!(Source, source.id).watch_window_days == nil
    assert Repo.get!(MediaProfile, profile.id).watch_window_days == 0
  end
end
