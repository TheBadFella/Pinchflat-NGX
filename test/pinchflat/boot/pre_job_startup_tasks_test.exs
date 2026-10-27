defmodule Pinchflat.Boot.PreJobStartupTasksTest do
  use Pinchflat.DataCase

  import Pinchflat.JobFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Downloading.FirstArtifact
  alias Pinchflat.Media
  alias Pinchflat.Settings
  alias Pinchflat.Boot.PreJobStartupTasks

  setup do
    stub(YtDlpRunnerMock, :version, fn -> {:ok, "1"} end)
    stub(AppriseRunnerMock, :version, fn -> {:ok, "2"} end)
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "3", 0} end)

    :ok
  end

  describe "ensure_tmpfile_directory" do
    test "creates the tmpfile directory if it doesn't exist" do
      tmpfile_dir = Application.get_env(:pinchflat, :tmpfile_directory)
      File.rm_rf!(tmpfile_dir)

      refute File.exists?(tmpfile_dir)

      PreJobStartupTasks.init(%{})

      assert File.exists?(tmpfile_dir)
    end
  end

  test "startup retains only pending journal-owned staging in both roots" do
    original_root = Application.get_env(:pinchflat, :download_staging_directory)
    configured = Path.join(Application.fetch_env!(:pinchflat, :tmpfile_directory), "pending-first-stage")
    File.mkdir_p!(configured)
    Application.put_env(:pinchflat, :download_staging_directory, configured)
    on_exit(fn -> Application.put_env(:pinchflat, :download_staging_directory, original_root) end)
    stub(DiskSpaceCheckerMock, :available_bytes, fn _ -> {:ok, 1_000_000_000_000} end)

    for root <- [configured, DownloadStaging.replacement_directory()] do
      item = media_item_fixture(%{media_filepath: nil})
      {:ok, started} = Media.update_media_item(item, %{watch_download_started_at: DateTime.utc_now()})
      {:ok, stage} = DownloadStaging.prepare(item.id, root: root)
      {:ok, unowned} = DownloadStaging.prepare(item.id, root: root)
      staged_media = Path.join(stage, "video-#{item.uuid}.mp4")
      staged_sidecar = Path.join(stage, "video-#{item.uuid}.json")
      active_media = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "video-#{item.uuid}.mp4")
      active_sidecar = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "video-#{item.uuid}.json")
      File.write!(staged_media, "first artifact")
      File.write!(staged_sidecar, "recoverable sidecar")
      assert :ok = FirstArtifact.remember(started, %{"filepath" => active_media}, staged_media,
        %{staged_media => active_media, staged_sidecar => active_sidecar}, stage)
      File.rename!(staged_media, active_media)
      assert :ok = File.touch(stage, {{2020, 1, 1}, {0, 0, 0}})
      assert :ok = File.touch(unowned, {{2020, 1, 1}, {0, 0, 0}})
    end

    assert {:ok, _} = PreJobStartupTasks.init(%{})

    for root <- [configured, DownloadStaging.replacement_directory()] do
      assert [stage] = File.ls!(root)
      assert String.starts_with?(stage, "media-")
      assert File.ls!(Path.join(root, stage)) |> Enum.any?(&String.ends_with?(&1, ".json"))
    end
  end

  describe "reset_executing_jobs" do
    test "resets executing jobs" do
      job = job_fixture()
      Repo.update_all(Oban.Job, set: [state: "executing"])

      assert Repo.reload!(job).state == "executing"

      PreJobStartupTasks.init(%{})

      assert Repo.reload!(job).state == "retryable"
    end
  end

  describe "revive_stalled_reconcile_jobs" do
    test "resets a stalled reconcile job left at its attempt ceiling" do
      {:ok, job} =
        %{"op" => "apply", "plan_id" => 1}
        |> Pinchflat.Reconciliation.ReconcileWorker.new()
        |> Oban.insert()

      # Mimic an apply that was executing at an ungraceful shutdown: reset_executing_jobs
      # will flip it executing -> retryable, leaving it at attempt == max_attempts (1)
      Repo.update_all(Oban.Job, set: [state: "executing", attempt: 1])

      PreJobStartupTasks.init(%{})

      reloaded = Repo.reload!(job)
      assert reloaded.state == "available"
      assert reloaded.attempt == 0
    end

    test "leaves a healthy pending reconcile job untouched" do
      {:ok, job} =
        %{"op" => "build", "plan_id" => 1}
        |> Pinchflat.Reconciliation.ReconcileWorker.new()
        |> Oban.insert()

      assert Repo.reload!(job).state == "available"
      assert Repo.reload!(job).attempt == 0

      PreJobStartupTasks.init(%{})

      # attempt 0 < max_attempts 1, so it isn't stalled and isn't disturbed
      assert Repo.reload!(job).state == "available"
    end
  end

  describe "create_blank_yt_dlp_files" do
    test "creates a blank cookie file" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join(base_dir, "cookies.txt")
      File.rm(filepath)

      refute File.exists?(filepath)

      PreJobStartupTasks.init(%{})

      assert File.exists?(filepath)
    end

    test "creates a blank yt-dlp config file" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join([base_dir, "yt-dlp-configs", "base-config.txt"])
      File.rm(filepath)

      refute File.exists?(filepath)

      PreJobStartupTasks.init(%{})

      assert File.exists?(filepath)
    end
  end

  describe "create_blank_user_script_file" do
    test "creates a blank script file" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join([base_dir, "user-scripts", "lifecycle"])
      File.rm(filepath)

      refute File.exists?(filepath)

      PreJobStartupTasks.init(%{})

      assert File.exists?(filepath)
    end

    test "gives it 755 permissions" do
      base_dir = Application.get_env(:pinchflat, :extras_directory)
      filepath = Path.join([base_dir, "user-scripts", "lifecycle"])
      File.rm(filepath)

      PreJobStartupTasks.init(%{})

      assert File.stat!(filepath).mode == 0o100755
    end
  end

  describe "apply_default_settings" do
    test "sets yt_dlp version" do
      File.rm_rf!(Application.get_env(:pinchflat, :tmpfile_directory))
      Settings.set(yt_dlp_version: nil)

      refute Settings.get!(:yt_dlp_version)

      PreJobStartupTasks.init(%{})

      assert Settings.get!(:yt_dlp_version)
    end

    test "sets apprise version" do
      File.rm_rf!(Application.get_env(:pinchflat, :tmpfile_directory))
      Settings.set(apprise_version: nil)

      refute Settings.get!(:apprise_version)

      PreJobStartupTasks.init(%{})

      assert Settings.get!(:apprise_version)
    end
  end

  describe "run_app_init_script" do
    test "calls the app_init user script runner" do
      expect(UserScriptRunnerMock, :run, fn :app_init, data ->
        assert data == %{}

        {:ok, "", 0}
      end)

      PreJobStartupTasks.init(%{})
    end
  end
end
