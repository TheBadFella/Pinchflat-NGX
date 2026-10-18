defmodule Pinchflat.YoutubeBrowser.SubscriptionTest do
  use Pinchflat.DataCase

  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task
  alias Pinchflat.YoutubeBrowser.Intake

  describe "subscribe_channel/3 core behavior" do
    test "B18: creates channel source with safe defaults and schedules indexing and metadata tasks" do
      profile = media_profile_fixture()

      source_count_before = Repo.aggregate(Source, :count, :id)

      assert {:ok, %Source{} = source} =
               Intake.subscribe_channel("UC_new_channel_123", profile.id, channel_title: "Tech Creators")

      assert Repo.aggregate(Source, :count, :id) == source_count_before + 1

      assert source.collection_id == "UC_new_channel_123"
      assert source.collection_type == :channel
      assert source.source_type == :channel
      assert source.custom_name == "Tech Creators"
      assert source.original_url == "https://www.youtube.com/channel/UC_new_channel_123"
      assert source.media_profile_id == profile.id
      assert source.index_frequency_minutes == 180
      assert source.enabled == true

      tasks = Repo.all(from t in Task, where: t.source_id == ^source.id, preload: [:job])
      assert length(tasks) == 2

      worker_names = Enum.map(tasks, & &1.job.worker)
      assert "Pinchflat.SlowIndexing.MediaCollectionIndexingWorker" in worker_names
      assert "Pinchflat.Metadata.SourceMetadataStorageWorker" in worker_names
    end

    test "B18: deduplicates and refuses re-subscription if channel already tracked under this profile" do
      profile = media_profile_fixture()

      existing_source =
        source_fixture(%{
          media_profile_id: profile.id,
          collection_type: :channel,
          collection_id: "UC_already_there",
          custom_name: "Original Channel Name"
        })

      assert {:error, {:already_tracked, found_source}} =
               Intake.subscribe_channel("UC_already_there", profile.id, channel_title: "New Name Attempt")

      assert found_source.id == existing_source.id
      assert found_source.custom_name == "Original Channel Name"

      # Total count unchanged
      assert Repo.aggregate(from(s in Source, where: s.collection_id == "UC_already_there"), :count, :id) == 1
    end

    test "B18: does NOT auto-enable an intentionally disabled/paused channel source" do
      profile = media_profile_fixture()

      disabled_source =
        source_fixture(%{
          media_profile_id: profile.id,
          collection_type: :channel,
          collection_id: "UC_disabled_channel",
          enabled: false
        })

      assert {:error, {:already_tracked, found_source}} =
               Intake.subscribe_channel("UC_disabled_channel", profile.id)

      assert found_source.id == disabled_source.id
      assert found_source.enabled == false

      # Re-fetch from DB to verify enabled was untouched
      fresh = Repo.get!(Source, disabled_source.id)
      assert fresh.enabled == false
    end

    test "B18: allows subscribing to the same channel under a different media profile" do
      profile_1 = media_profile_fixture(%{name: "Profile 1"})
      profile_2 = media_profile_fixture(%{name: "Profile 2"})

      # Subscribe under profile 1
      assert {:ok, %Source{} = s1} =
               Intake.subscribe_channel("UC_multi_prof", profile_1.id, channel_title: "Channel Multi")

      # Subscribe under profile 2
      assert {:ok, %Source{} = s2} =
               Intake.subscribe_channel("UC_multi_prof", profile_2.id, channel_title: "Channel Multi")

      assert s1.id != s2.id
      assert s1.media_profile_id == profile_1.id
      assert s2.media_profile_id == profile_2.id
    end
  end

  describe "safety boundaries and invalid inputs" do
    test "B14: rejects invalid or non-existent profile ID" do
      assert {:error, :invalid_profile} = Intake.subscribe_channel("UC_123", 999_999)
      assert {:error, :invalid_profile} = Intake.subscribe_channel("UC_123", nil)
    end

    test "B14: rejects malformed channel ID" do
      profile = media_profile_fixture()
      assert {:error, :invalid_channel_id} = Intake.subscribe_channel("", profile.id)
      assert {:error, :invalid_channel_id} = Intake.subscribe_channel("invalid/slash/id", profile.id)
    end

    test "B09: refuses subscription when postgres migration hold is active" do
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
      on_exit(fn -> Application.delete_env(:pinchflat, :postgres_migration_boot_held) end)

      profile = media_profile_fixture()
      assert {:error, :migration_hold_active} = Intake.subscribe_channel("UC_held", profile.id)
    end

    test "B09: refuses subscription when legacy migration hold is active" do
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      profile = media_profile_fixture()
      assert {:error, :migration_hold_active} = Intake.subscribe_channel("UC_held", profile.id)
    end
  end
end
