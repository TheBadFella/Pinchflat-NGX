defmodule Pinchflat.Downloading.SpaceProtectionTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.SpaceProtection
  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @default_threshold 10_737_418_240
  @ten_gib 10 * 1024 * 1024 * 1024
  @eleven_gib 11 * 1024 * 1024 * 1024
  @five_gib 5 * 1024 * 1024 * 1024
  @twenty_gib 20 * 1024 * 1024 * 1024

  setup do
    Settings.set(download_space_protection_enabled: false)
    Settings.set(download_space_protection_threshold_bytes: @default_threshold)
    Settings.set(download_space_protection_blocked: false)
    Settings.set(download_space_protection_blocked_reason: nil)
    Settings.set(download_space_protection_blocked_location: nil)
    Settings.set(download_space_protection_free_bytes: nil)
    Settings.set(apprise_server: "http://apprise.example.com")

    on_exit(fn ->
      Settings.set(download_space_protection_enabled: false)
      Settings.set(download_space_protection_blocked: false)
      Application.delete_env(:pinchflat, :download_staging_directory)
    end)

    :ok
  end

  describe "threshold calculations" do
    test "default_threshold_bytes/0 returns 10 GiB" do
      assert SpaceProtection.default_threshold_bytes() == @default_threshold
    end

    test "recovery_threshold_bytes/1 adds 1 GiB hysteresis" do
      assert SpaceProtection.recovery_threshold_bytes(@ten_gib) == @eleven_gib
    end
  end

  describe "preflight/1 when disabled" do
    test "returns :ok without checking disk space" do
      assert SpaceProtection.preflight(nil) == :ok
      refute Settings.get!(:download_space_protection_blocked)
    end
  end

  describe "preflight/1 when enabled" do
    setup do
      Settings.set(download_space_protection_enabled: true)
      :ok
    end

    test "returns :ok when disk space is sufficient" do
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, @twenty_gib} end)

      assert SpaceProtection.preflight(nil) == :ok
      refute Settings.get!(:download_space_protection_blocked)
    end

    test "snoozes, blocks and alerts when space is low" do
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, @five_gib} end)

      expect(AppriseRunnerMock, :run, fn server, opts ->
        assert server == "http://apprise.example.com"
        assert opts[:title] =~ "Downloads paused"
        assert opts[:body] =~ "destination"
        refute Keyword.has_key?(opts, :input_format)
        refute opts[:body] =~ "**"
        {:ok, "Alert sent"}
      end)

      assert {:snooze, 60} = SpaceProtection.preflight(nil)

      assert Settings.get!(:download_space_protection_blocked) == true
      assert Settings.get!(:download_space_protection_blocked_reason) == "low_space"
      assert Settings.get!(:download_space_protection_blocked_location) == "destination"
      assert Settings.get!(:download_space_protection_free_bytes) == @five_gib
      refute is_nil(Settings.get!(:download_space_protection_blocked_at))
      refute is_nil(Settings.get!(:download_space_protection_alerted_at))
    end

    test "deduplicates alerts when already blocked" do
      Settings.set(download_space_protection_blocked: true)
      Settings.set(download_space_protection_blocked_reason: "low_space")
      Settings.set(download_space_protection_blocked_location: "destination")

      # AppriseRunnerMock should NOT be called
      assert {:snooze, 60} = SpaceProtection.preflight(nil)
    end

    test "remains safely blocked even if Apprise alert fails" do
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, @five_gib} end)

      expect(AppriseRunnerMock, :run, fn _server, _opts ->
        {:error, "Connection refused"}
      end)

      assert {:snooze, 60} = SpaceProtection.preflight(nil)
      assert Settings.get!(:download_space_protection_blocked) == true
      assert is_nil(Settings.get!(:download_space_protection_alerted_at))
    end

    test "retries alert on subsequent preflight when previously blocked without alert timestamp" do
      Settings.set(download_space_protection_blocked: true)
      Settings.set(download_space_protection_blocked_reason: "low_space")
      Settings.set(download_space_protection_blocked_location: "destination")
      Settings.set(download_space_protection_alerted_at: nil)

      expect(AppriseRunnerMock, :run, fn _server, _opts ->
        {:ok, "Delivered"}
      end)

      assert {:snooze, 60} = SpaceProtection.preflight(nil)
      refute is_nil(Settings.get!(:download_space_protection_alerted_at))
    end

    test "updates task progress status when job_id is provided" do
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, @five_gib} end)
      stub(AppriseRunnerMock, :run, fn _server, _opts -> {:ok, ""} end)

      media_item = media_item_fixture()
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      assert {:snooze, 60} = SpaceProtection.preflight(task.job_id)

      reloaded_task = Repo.reload!(task)
      assert reloaded_task.progress_status == "Waiting for storage space"
    end

    test "checks active staging storage when configured" do
      staging_dir = Path.join(System.tmp_dir!(), "pinchflat_test_staging_#{Ecto.UUID.generate()}")
      File.mkdir_p!(staging_dir)
      on_exit(fn -> File.rm_rf(staging_dir) end)

      Application.put_env(:pinchflat, :download_staging_directory, staging_dir)

      # Destination is sufficient, but staging is low
      expect(DiskSpaceCheckerMock, :available_bytes, 2, fn path ->
        if String.contains?(path, "pinchflat_test_staging") do
          {:ok, @five_gib}
        else
          {:ok, @twenty_gib}
        end
      end)

      stub(AppriseRunnerMock, :run, fn _server, _opts -> {:ok, ""} end)

      assert {:snooze, 60} = SpaceProtection.preflight(nil)
      assert Settings.get!(:download_space_protection_blocked) == true
      assert Settings.get!(:download_space_protection_blocked_location) == "staging"
    end

    test "blocks when disk capacity cannot be determined" do
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> :error end)
      stub(AppriseRunnerMock, :run, fn _server, _opts -> {:ok, ""} end)

      assert {:snooze, 60} = SpaceProtection.preflight(nil)
      assert Settings.get!(:download_space_protection_blocked) == true
      assert Settings.get!(:download_space_protection_blocked_reason) == "unknown_capacity"
    end
  end

  describe "manual_resume/0" do
    setup do
      Settings.set(download_space_protection_enabled: true)
      :ok
    end

    test "returns {:ok, :not_blocked} if not currently blocked" do
      assert SpaceProtection.manual_resume() == {:ok, :not_blocked}
    end

    test "rejects resume if available space is below recovery threshold (threshold + 1 GiB)" do
      Settings.set(download_space_protection_blocked: true)
      Settings.set(download_space_protection_threshold_bytes: @ten_gib)

      # 10.5 GiB is above threshold but BELOW recovery threshold (11 GiB)
      ten_and_half_gib = 10 * 1024 * 1024 * 1024 + 512 * 1024 * 1024
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, ten_and_half_gib} end)

      assert {:error, :below_recovery_threshold, ^ten_and_half_gib, @eleven_gib, "destination"} =
               SpaceProtection.manual_resume()

      assert Settings.get!(:download_space_protection_blocked) == true
    end

    test "resumes and clears block when space is at or above recovery threshold" do
      Settings.set(download_space_protection_blocked: true)
      Settings.set(download_space_protection_threshold_bytes: @ten_gib)

      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, @twenty_gib} end)

      assert {:ok, :resumed} = SpaceProtection.manual_resume()
      assert Settings.get!(:download_space_protection_blocked) == false
      assert is_nil(Settings.get!(:download_space_protection_blocked_reason))
    end
  end

  describe "sync_settings_state/2" do
    test "clears block when protection is disabled" do
      old_setting = %{Settings.record() | download_space_protection_enabled: true}
      Settings.set(download_space_protection_blocked: true)
      new_setting = %{Settings.record() | download_space_protection_enabled: false}

      SpaceProtection.sync_settings_state(old_setting, new_setting)
      assert Settings.get!(:download_space_protection_blocked) == false
    end
  end

  describe "MediaDownloadWorker preflight integration" do
    setup do
      Settings.set(download_space_protection_enabled: true)
      Settings.set(download_space_protection_threshold_bytes: @ten_gib)

      media_item =
        %{media_filepath: nil}
        |> media_item_fixture()
        |> Repo.preload([:metadata, source: :media_profile])

      {:ok, %{media_item: media_item}}
    end

    test "snoozes without running user scripts, yt-dlp, or clearing errors even when force=true", %{
      media_item: media_item
    } do
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, @five_gib} end)
      stub(AppriseRunnerMock, :run, fn _server, _opts -> {:ok, ""} end)

      # Neither UserScriptRunnerMock nor YtDlpRunnerMock should be called!
      res = perform_job(MediaDownloadWorker, %{id: media_item.id, force: true, reset_last_error: true})

      assert res == {:snooze, 60}
      assert Settings.get!(:download_space_protection_blocked) == true

      # Media item remains in its original state
      reloaded = Repo.reload!(media_item)
      assert is_nil(reloaded.media_filepath)
    end
  end
end
