defmodule Pinchflat.Downloading.MediaQualityUpgradeWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.MediaQualityUpgradeWorker
  alias Pinchflat.Downloading.MediaRetentionWorker

  describe "perform/1" do
    test "leaves expired media for retention when upgrades run before retention" do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
      profile = media_profile_fixture(%{redownload_delay_days: 4})
      expired_source = source_fixture(%{media_profile_id: profile.id, retention_period_days: 2})
      retained_source = source_fixture(%{media_profile_id: profile.id, retention_period_days: 7})
      downloaded_at = now_minus(5, :days) |> DateTime.truncate(:second)
      attrs = %{uploaded_at: now_minus(6, :days), media_downloaded_at: downloaded_at}
      expired = media_item_with_attachments(Map.put(attrs, :source_id, expired_source.id))
      retained = media_item_with_attachments(Map.put(attrs, :source_id, retained_source.id))

      assert :ok = perform_job(MediaQualityUpgradeWorker, %{})

      assert [job] = all_enqueued(worker: MediaDownloadWorker)
      assert job.args == %{"id" => retained.id, "quality_upgrade?" => true}
      assert Repo.reload!(expired).media_downloaded_at == downloaded_at
      assert File.exists?(expired.media_filepath)

      assert :ok = perform_job(MediaRetentionWorker, %{})

      refute File.exists?(expired.media_filepath)
      assert Repo.reload!(expired).prevent_download
      assert File.exists?(retained.media_filepath)
      refute Repo.reload!(retained).prevent_download
    end

    test "upgrades media with disabled retention or active deletion protection" do
      profile = media_profile_fixture(%{redownload_delay_days: 4})

      items =
        for {retention_days, prevent_culling} <- [{nil, false}, {0, false}, {2, true}] do
          source = source_fixture(%{media_profile_id: profile.id, retention_period_days: retention_days})

          media_item_fixture(%{
            source_id: source.id,
            uploaded_at: now_minus(6, :days),
            media_downloaded_at: now_minus(5, :days),
            prevent_culling: prevent_culling
          })
        end

      assert :ok = perform_job(MediaQualityUpgradeWorker, %{})

      assert length(all_enqueued(worker: MediaDownloadWorker)) == 3

      for item <- items do
        assert_enqueued(worker: MediaDownloadWorker, args: %{id: item.id, quality_upgrade?: true})
      end
    end

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
