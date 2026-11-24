defmodule Pinchflat.Downloading.MediaRetentionWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.MediaRetentionWorker
  alias Pinchflat.Media

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

    test "inherited age cleanup remains independent of publication cutoff and protection" do
      profile = media_profile_fixture(%{retention_period_days: 2})
      source = source_fixture(%{media_profile_id: profile.id, download_cutoff_date: Date.add(Date.utc_today(), -5)})

      protected =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: now_minus(7, :days),
          media_downloaded_at: now_minus(4, :days),
          prevent_culling: true
        })

      before_cutoff =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: now_minus(7, :days),
          media_downloaded_at: now_minus(1, :day)
        })

      expired =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: now_minus(3, :days),
          media_downloaded_at: now_minus(4, :days)
        })

      assert :ok = perform_job(MediaRetentionWorker, %{})
      assert File.exists?(protected.media_filepath)
      refute File.exists?(before_cutoff.media_filepath)
      refute Repo.reload!(before_cutoff).prevent_download
      refute File.exists?(expired.media_filepath)
      assert Repo.reload!(expired).prevent_download
    end

    test "existing and new inheriting sources follow profile edits and reassignment, unlike explicit overrides" do
      profile = media_profile_fixture()
      other_profile = media_profile_fixture(%{retention_period_days: 2})
      existing = source_fixture(%{media_profile_id: profile.id, retention_period_days: nil})
      inheriting = source_fixture(%{media_profile_id: profile.id})
      disabled = source_fixture(%{media_profile_id: profile.id, retention_period_days: 0})
      override = source_fixture(%{media_profile_id: profile.id, retention_period_days: 10})

      items =
        for source <- [existing, inheriting, disabled, override] do
          media_item_with_attachments(%{source_id: source.id, media_downloaded_at: now_minus(4, :days)})
        end

      assert :ok = perform_job(MediaRetentionWorker, %{})
      assert Enum.all?(items, &File.exists?(&1.media_filepath))

      {:ok, _} = Pinchflat.Profiles.update_media_profile(profile, %{retention_period_days: 2})
      assert Enum.map(items, &Media.retention_cullable?/1) == [true, true, false, false]

      # Moving one inheriting source to an unset profile restores the no-age-cleanup policy.
      {:ok, _} =
        Pinchflat.Sources.update_source(inheriting, %{media_profile_id: media_profile_fixture().id},
          run_post_commit_tasks: false
        )

      assert Enum.map(items, &Media.retention_cullable?/1) == [true, false, false, false]

      {:ok, _} =
        Pinchflat.Sources.update_source(inheriting, %{media_profile_id: other_profile.id}, run_post_commit_tasks: false)

      assert Enum.map(items, &Media.retention_cullable?/1) == [true, true, false, false]

      assert :ok = perform_job(MediaRetentionWorker, %{})
      assert Enum.map(items, &File.exists?(&1.media_filepath)) == [false, false, true, true]
      assert Enum.map(items, fn item -> Repo.reload!(item).prevent_download end) == [true, true, false, false]
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
      # culled_at is stored to the second, so allow for crossing a second boundary
      assert DateTime.diff(now(), Repo.reload!(old_media_item).culled_at) in 0..2
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

      profile = media_profile_fixture(%{retention_period_days: 2})
      source = source_fixture(%{media_profile_id: profile.id, retention_period_days: nil})
      old_media_item = media_item_with_attachments(%{source_id: source.id, media_downloaded_at: now_minus(3, :days)})

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

  describe "perform/1 when testing keep-newest retention" do
    test "deletes the oldest files beyond the newest N and leaves prevent_download false" do
      source = source_fixture(%{keep_newest_count: 3})

      items =
        for day <- 20..24 do
          media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(day)})
        end

      oldest = Enum.at(items, 0)
      second_oldest = Enum.at(items, 1)
      newest_three = Enum.take(items, -3)

      assert :ok = perform_job(MediaRetentionWorker, %{})

      refute File.exists?(oldest.media_filepath)
      refute File.exists?(second_oldest.media_filepath)

      assert Enum.all?(newest_three, &File.exists?(&1.media_filepath))

      for item <- [oldest, second_oldest] do
        reloaded = Repo.reload!(item)
        assert reloaded.culled_at
        refute reloaded.prevent_download
        assert is_nil(reloaded.media_filepath)
      end

      assert Enum.all?(newest_three, fn item -> is_nil(Repo.reload!(item).culled_at) end)
    end

    test "raising the limit makes previously culled items pending and download again" do
      source = source_fixture(%{keep_newest_count: 3})

      items =
        for day <- 20..24 do
          media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(day)})
        end

      culled_ids = items |> Enum.take(2) |> Enum.map(& &1.id)

      assert :ok = perform_job(MediaRetentionWorker, %{})

      # The two oldest fall outside the newest three, so they are not pending.
      assert Media.list_pending_media_items_for(source) == []
      assert DownloadingHelpers.enqueue_pending_download_tasks(source) == 0

      {:ok, _source} =
        Pinchflat.Sources.update_source(source, %{keep_newest_count: 5}, run_post_commit_tasks: false)

      # Raising N brings the culled items back into range, so they download again.
      assert Media.list_pending_media_items_for(source) |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort(culled_ids)
      assert DownloadingHelpers.enqueue_pending_download_tasks(source) == 2
    end

    test "does not remove a prevent_culling item and does not count it towards N" do
      source = source_fixture(%{keep_newest_count: 3})

      newest_protected =
        media_item_with_attachments(%{
          source_id: source.id,
          prevent_culling: true,
          uploaded_at: published_at(24)
        })

      unprotected =
        for day <- 20..23 do
          media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(day)})
        end

      assert :ok = perform_job(MediaRetentionWorker, %{})

      assert File.exists?(newest_protected.media_filepath)

      # The protected item does not consume a slot, so 21, 22 and 23 survive.
      for item <- Enum.take(unprotected, -3) do
        assert File.exists?(item.media_filepath)
      end

      refute File.exists?(Enum.at(unprotected, 0).media_filepath)
    end

    test "counts a watch-protected item towards N and never removes it" do
      source = source_fixture(%{keep_newest_count: 2})

      watch_protected =
        media_item_with_attachments(%{
          source_id: source.id,
          watch_enrollment_pending_at: now(),
          uploaded_at: published_at(24)
        })

      items =
        for day <- 20..23 do
          media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(day)})
        end

      assert :ok = perform_job(MediaRetentionWorker, %{})

      assert File.exists?(watch_protected.media_filepath)
      assert File.exists?(Enum.at(items, 3).media_filepath)
      refute File.exists?(Enum.at(items, 0).media_filepath)
      refute File.exists?(Enum.at(items, 1).media_filepath)
      refute File.exists?(Enum.at(items, 2).media_filepath)
    end

    test "does not remove items with an active download job" do
      source = source_fixture(%{keep_newest_count: 2})

      oldest_with_job = media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(20)})
      _newer = media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(23)})
      _newest = media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(24)})

      # The item stays downloaded (media_filepath is set), but a queued download
      # job must keep the cleanup from deleting the file underneath it.
      assert {:ok, _task} =
               Pinchflat.Downloading.MediaDownloadWorker.kickoff_with_task(oldest_with_job, %{force: true})

      assert :ok = perform_job(MediaRetentionWorker, %{})

      assert File.exists?(oldest_with_job.media_filepath)
      assert Repo.reload!(oldest_with_job).media_filepath
      refute Repo.reload!(oldest_with_job).culled_at
    end

    test "retention, cutoff and count limit each remove distinct items and protection overrides all three" do
      source =
        source_fixture(%{
          keep_newest_count: 2,
          download_cutoff_date: Date.new!(2026, 11, 21),
          retention_period_days: 1
        })

      protected =
        media_item_with_attachments(%{
          source_id: source.id,
          prevent_culling: true,
          uploaded_at: published_at(18),
          media_downloaded_at: now_minus(30, :days)
        })

      past_retention =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: published_at(19),
          media_downloaded_at: now_minus(30, :days)
        })

      before_cutoff =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: published_at(20),
          media_downloaded_at: now()
        })

      beyond_count =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: published_at(21),
          media_downloaded_at: now()
        })

      kept_a =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: published_at(23),
          media_downloaded_at: now()
        })

      kept_b =
        media_item_with_attachments(%{
          source_id: source.id,
          uploaded_at: published_at(24),
          media_downloaded_at: now()
        })

      assert :ok = perform_job(MediaRetentionWorker, %{})

      # The protected item survives every rule, even though it is old enough and
      # beyond the count limit.
      assert File.exists?(protected.media_filepath)

      # Each independent rule removes its own item; the two newest stay.
      refute File.exists?(past_retention.media_filepath)
      refute File.exists?(before_cutoff.media_filepath)
      refute File.exists?(beyond_count.media_filepath)
      assert File.exists?(kept_a.media_filepath)
      assert File.exists?(kept_b.media_filepath)
    end

    test "leaves sources without keep_newest_count untouched" do
      source = source_fixture(%{keep_newest_count: nil})

      items =
        for day <- 20..24 do
          media_item_with_attachments(%{source_id: source.id, uploaded_at: published_at(day)})
        end

      assert :ok = perform_job(MediaRetentionWorker, %{})

      assert Enum.all?(items, &File.exists?(&1.media_filepath))
      assert Enum.all?(items, fn item -> is_nil(Repo.reload!(item).culled_at) end)
    end
  end

  defp published_at(day) do
    DateTime.new!(Date.new!(2026, 11, day), ~T[00:00:00], "Etc/UTC")
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
