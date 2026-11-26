defmodule Pinchflat.Profiles.MediaProfileDeletionWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles.MediaProfileDeletionWorker

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> :ok end)

    {:ok, %{profile: media_profile_fixture()}}
  end

  describe "kickoff/3" do
    test "starts the worker", %{profile: profile} do
      assert [] = all_enqueued(worker: MediaProfileDeletionWorker)
      assert {:ok, _} = MediaProfileDeletionWorker.kickoff(profile)
      assert [_] = all_enqueued(worker: MediaProfileDeletionWorker)
    end

    test "can be called with additional job arguments", %{profile: profile} do
      job_args = %{"delete_files" => true}

      assert {:ok, _} = MediaProfileDeletionWorker.kickoff(profile, job_args)

      assert_enqueued(worker: MediaProfileDeletionWorker, args: %{"id" => profile.id, "delete_files" => true})
    end
  end

  describe "perform/1" do
    test "deletes the profile, sources, and media but leaves the files", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_with_attachments(%{source_id: source.id})

      perform_job(MediaProfileDeletionWorker, %{"id" => profile.id})

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(profile) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
      assert File.exists?(media_item.media_filepath)
    end

    test "deletes the profile, sources, and media and files if specified", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_with_attachments(%{source_id: source.id})

      perform_job(MediaProfileDeletionWorker, %{"id" => profile.id, "delete_files" => true})

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(profile) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
      refute File.exists?(media_item.media_filepath)
    end

    test "clears default_media_profile_id and invalidates warm settings cache on deletion", %{profile: profile} do
      original_cache = Application.get_env(:pinchflat, :settings_cache)
      Application.put_env(:pinchflat, :settings_cache, true)
      Pinchflat.Settings.invalidate_cache()

      on_exit(fn ->
        Pinchflat.Settings.invalidate_cache()

        if is_nil(original_cache),
          do: Application.delete_env(:pinchflat, :settings_cache),
          else: Application.put_env(:pinchflat, :settings_cache, original_cache)
      end)

      assert {:ok, ^profile} = Pinchflat.Profiles.set_default_media_profile(profile.id)
      assert Pinchflat.Settings.get!(:default_media_profile_id) == profile.id

      assert :ok = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id}) |> elem(0) |> then(fn _ -> :ok end)
      assert is_nil(Pinchflat.Settings.record().default_media_profile_id)
      assert is_nil(Pinchflat.Profiles.default_media_profile_id())
    end
  end
end
