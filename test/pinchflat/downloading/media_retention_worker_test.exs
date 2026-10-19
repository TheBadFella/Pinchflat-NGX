defmodule Pinchflat.Downloading.MediaRetentionWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media
  alias Pinchflat.Downloading.MediaRetentionWorker

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

    :ok
  end

  describe "perform/1" do
    test "cutoff and age cleanup are independent and protection overrides both" do
      for {days, upload_days, download_days, protected?, deleted?} <- [
            {10, 4, 1, false, true},
            {nil, 4, 1, false, true},
            {0, 4, 1, false, true},
            {10, 4, 1, true, false},
            {10, 4, 11, true, false},
            {10, 2, 1, false, false},
            {10, 1, 11, false, true},
            {0, 1, 11, false, false}
          ] do
        source = source_fixture(download_cutoff_date: Date.add(Date.utc_today(), -2), retention_period_days: days)

        item =
          media_item_with_attachments(%{
            source_id: source.id,
            uploaded_at: now_minus(upload_days, :days),
            media_downloaded_at: now_minus(download_days, :days),
            prevent_culling: protected?
          })

        assert :ok = perform_job(MediaRetentionWorker, %{})

        assert File.exists?(item.media_filepath) == not deleted?,
               "unexpected file survival for #{inspect({days, upload_days, download_days, protected?})}"

        assert is_nil(Repo.reload!(item).media_filepath) == deleted?
      end
    end

    test "sets deleted media to not re-download" do
      {_source, old_media_item, new_media_item} = prepare_records_for_retention_date()

      perform_job(MediaRetentionWorker, %{})

      refute Repo.reload!(new_media_item).prevent_download
      assert Repo.reload!(old_media_item).prevent_download
    end

    test "sets culled_at timestamp on deleted media" do
      {_source, old_media_item, new_media_item} = prepare_records_for_retention_date()

      perform_job(MediaRetentionWorker, %{})

      refute Repo.reload!(new_media_item).culled_at
      assert Repo.reload!(old_media_item).culled_at
      assert DateTime.diff(now(), Repo.reload!(old_media_item).culled_at) < 1
    end

    test "skips culling when legacy migration review is pending" do
      test_state_file =
        Path.join(System.tmp_dir!(), "retention_test_#{System.unique_integer([:positive])}.json")

      Application.put_env(:pinchflat, :legacy_migration_state_path, test_state_file)
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      on_exit(fn ->
        Application.delete_env(:pinchflat, :legacy_migration_state_path)
        File.rm(test_state_file)
      end)

      {_source, old_media_item, _new_media_item} = prepare_records_for_retention_date()

      assert :ok = perform_job(MediaRetentionWorker, %{})

      assert File.exists?(old_media_item.media_filepath)
      refute Repo.reload!(old_media_item).prevent_download
    end
  end

  describe "perform/1 when testing retention_period-based culling" do
    test "deletes media files that are past their retention date" do
      {_source, old_media_item, new_media_item} = prepare_records_for_retention_date()

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(new_media_item.media_filepath)
      refute File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(new_media_item).media_filepath
      refute Repo.reload!(old_media_item).media_filepath
    end

    test "deletes media files that are on their retention date per the 24-h clock" do
      {_source, old_media_item, new_media_item} = prepare_records_for_retention_date(2)

      just_over_two_days_ago = now_minus(2, :days) |> DateTime.add(-1, :minute)
      just_under_two_days_ago = now_minus(2, :days) |> DateTime.add(1, :minute)

      Media.update_media_item(old_media_item, %{media_downloaded_at: just_over_two_days_ago})
      Media.update_media_item(new_media_item, %{media_downloaded_at: just_under_two_days_ago})

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(new_media_item.media_filepath)
      refute File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(new_media_item).media_filepath
      refute Repo.reload!(old_media_item).media_filepath
    end

    test "sets culled_at and prevent_download" do
      {_source, old_media_item, new_media_item} = prepare_records_for_retention_date()

      perform_job(MediaRetentionWorker, %{})

      refute Repo.reload!(new_media_item).culled_at
      assert Repo.reload!(old_media_item).culled_at
      refute Repo.reload!(new_media_item).prevent_download
      assert Repo.reload!(old_media_item).prevent_download
    end

    test "doesn't cull if the source doesn't have a retention period" do
      {_source, old_media_item, new_media_item} = prepare_records_for_retention_date(nil)

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(new_media_item.media_filepath)
      assert File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(new_media_item).media_filepath
      assert Repo.reload!(old_media_item).media_filepath

      refute Repo.reload!(new_media_item).culled_at
      refute Repo.reload!(old_media_item).culled_at
    end

    test "doesn't cull media items that have prevent_culling set" do
      {_source, old_media_item, _new_media_item} = prepare_records_for_retention_date()

      Media.update_media_item(old_media_item, %{prevent_culling: true})

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(old_media_item).media_filepath
      refute Repo.reload!(old_media_item).culled_at
    end

    test "doesn't cull if the media item has no media_filepath" do
      {_source, old_media_item, _new_media_item} = prepare_records_for_retention_date()

      Media.update_media_item(old_media_item, %{media_filepath: nil})

      perform_job(MediaRetentionWorker, %{})

      refute Repo.reload!(old_media_item).culled_at
    end
  end

  describe "perform/1 when testing source cutoff-based culling" do
    test "culls media from before the cutoff date" do
      {_source, old_media_item, new_media_item} = prepare_records_for_source_cutoff_date()

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(new_media_item.media_filepath)
      refute File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(new_media_item).media_filepath
      refute Repo.reload!(old_media_item).media_filepath
    end

    # NOTE: Since this is a date and not a datetime, we can't add logic to have to-the-minute
    # comparison like we can with retention periods. We can only compare to the day.
    test "doesn't cull media from on or after the cutoff date" do
      {_source, old_media_item, new_media_item} = prepare_records_for_source_cutoff_date(2)

      Media.update_media_item(old_media_item, %{uploaded_at: now_minus(2, :days)})
      Media.update_media_item(new_media_item, %{uploaded_at: now_minus(1, :day)})

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(new_media_item.media_filepath)
      assert File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(new_media_item).media_filepath
      assert Repo.reload!(old_media_item).media_filepath

      refute Repo.reload!(new_media_item).culled_at
      refute Repo.reload!(old_media_item).culled_at
    end

    test "sets culled_at but not prevent_download" do
      {_source, old_media_item, new_media_item} = prepare_records_for_source_cutoff_date()

      perform_job(MediaRetentionWorker, %{})

      refute Repo.reload!(new_media_item).culled_at
      assert Repo.reload!(old_media_item).culled_at
      refute Repo.reload!(new_media_item).prevent_download
      refute Repo.reload!(old_media_item).prevent_download
    end

    test "doesn't cull media if the source doesn't have a cutoff date" do
      {_source, old_media_item, new_media_item} = prepare_records_for_source_cutoff_date(nil)

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(new_media_item.media_filepath)
      assert File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(new_media_item).media_filepath
      assert Repo.reload!(old_media_item).media_filepath

      refute Repo.reload!(new_media_item).culled_at
      refute Repo.reload!(old_media_item).culled_at
    end

    test "doesn't cull media items that have prevent_culling set" do
      {_source, old_media_item, _new_media_item} = prepare_records_for_source_cutoff_date()

      Media.update_media_item(old_media_item, %{prevent_culling: true})

      perform_job(MediaRetentionWorker, %{})

      assert File.exists?(old_media_item.media_filepath)
      assert Repo.reload!(old_media_item).media_filepath
      refute Repo.reload!(old_media_item).culled_at
    end

    test "doesn't cull if the media item has no media_filepath" do
      {_source, old_media_item, _new_media_item} = prepare_records_for_source_cutoff_date()

      Media.update_media_item(old_media_item, %{media_filepath: nil})

      perform_job(MediaRetentionWorker, %{})

      refute Repo.reload!(old_media_item).culled_at
    end
  end

  defp prepare_records_for_retention_date(retention_period_days \\ 2) do
    source = source_fixture(%{retention_period_days: retention_period_days})

    old_media_item =
      media_item_with_attachments(%{
        source_id: source.id,
        media_downloaded_at: now_minus(3, :days)
      })

    new_media_item =
      media_item_with_attachments(%{
        source_id: source.id,
        media_downloaded_at: now_minus(1, :day)
      })

    {source, old_media_item, new_media_item}
  end

  defp prepare_records_for_source_cutoff_date(download_cutoff_date_days_ago \\ 2) do
    cutoff_date = if download_cutoff_date_days_ago, do: now_minus(download_cutoff_date_days_ago, :days), else: nil
    source = source_fixture(%{download_cutoff_date: cutoff_date})

    old_media_item =
      media_item_with_attachments(%{
        source_id: source.id,
        uploaded_at: now_minus(3, :days)
      })

    new_media_item =
      media_item_with_attachments(%{
        source_id: source.id,
        uploaded_at: now_minus(1, :day)
      })

    {source, old_media_item, new_media_item}
  end
end
