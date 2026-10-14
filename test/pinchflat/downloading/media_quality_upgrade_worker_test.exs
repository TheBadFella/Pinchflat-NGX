defmodule Pinchflat.Downloading.MediaQualityUpgradeWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.MediaQualityUpgradeWorker

  describe "perform/1" do
    test "kicks off a task for redownloadable media items" do
      media_profile = media_profile_fixture(%{redownload_delay_days: 4})
      source = source_fixture(%{media_profile_id: media_profile.id, inserted_at: now_minus(10, :days)})

      media_item =
        media_item_fixture(%{
          source_id: source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(5, :days)
        })

      perform_job(MediaQualityUpgradeWorker, %{})

      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{id: media_item.id, quality_upgrade?: true})
    end

    test "does not kickoff a task for non-redownloadable media items" do
      media_profile = media_profile_fixture(%{redownload_delay_days: 4})
      source = source_fixture(%{media_profile_id: media_profile.id, inserted_at: now_minus(10, :days)})

      _media_item =
        media_item_fixture(%{
          source_id: source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(1, :day)
        })

      perform_job(MediaQualityUpgradeWorker, %{})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "skips upgrading when legacy migration review is pending" do
      test_state_file =
        Path.join(System.tmp_dir!(), "upgrade_test_#{System.unique_integer([:positive])}.json")

      Application.put_env(:pinchflat, :legacy_migration_state_path, test_state_file)
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      on_exit(fn ->
        Application.delete_env(:pinchflat, :legacy_migration_state_path)
        File.rm(test_state_file)
      end)

      media_profile = media_profile_fixture(%{redownload_delay_days: 4})
      source = source_fixture(%{media_profile_id: media_profile.id, inserted_at: now_minus(10, :days)})

      _media_item =
        media_item_fixture(%{
          source_id: source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(5, :days)
        })

      assert :ok = perform_job(MediaQualityUpgradeWorker, %{})
      assert [] = all_enqueued(worker: MediaDownloadWorker)
    end
  end
end
