defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Utils.FilesystemUtils

  describe "show settings" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/settings")
      html = html_response(conn, 200)

      assert html =~ "Settings"
      assert html =~ "Search settings..."
      assert html =~ "Notification Settings"
      assert html =~ "Extractor Settings"
      assert html =~ "Cookies"
      assert html =~ "Base yt-dlp Config"
      assert html =~ "PostgreSQL Backups"
      assert html =~ ~s(href="/backups")
      refute html =~ ~s(data-settings-group="backups")
      refute html =~ ~s(id="postgres-backups")
      assert html =~ "Review PostgreSQL migration"
      assert html =~ ~s(href="/postgres_migration")
    end
  end

  test "migration setup is discoverable without enabling a transfer", %{conn: conn} do
    html = conn |> get(~p"/postgres_migration") |> html_response(200)

    if Pinchflat.Database.sqlite?() do
      assert html =~ "This installation uses SQLite"
      assert html =~ "SQLITE_MIGRATION_SOURCE"
      assert html =~ "DATABASE_URL"
    else
      assert html =~ "This installation already uses PostgreSQL"
    end

    refute html =~ ~s(action="/postgres_migration/start")
  end

  describe "update settings" do
    test "saves and disables video titles in notifications", %{conn: conn} do
      refute Pinchflat.Settings.get!(:notification_include_video_titles)

      updated = put(conn, ~p"/settings", setting: %{notification_include_video_titles: "true"})
      assert redirected_to(updated) == ~p"/settings"
      assert Pinchflat.Settings.get!(:notification_include_video_titles)

      html = conn |> get(~p"/settings") |> html_response(200)
      assert html =~ "Include video titles"
      assert html =~ ~s(name="setting[notification_include_video_titles]")

      disabled = put(conn, ~p"/settings", setting: %{notification_include_video_titles: "false"})
      assert redirected_to(disabled) == ~p"/settings"
      refute Pinchflat.Settings.get!(:notification_include_video_titles)
    end

    test "filters credentials in settings request logs", %{conn: conn} do
      previous_level = Logger.level()
      Logger.configure(level: :debug)

      try do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            changed =
              put(conn, ~p"/settings",
                setting: %{
                  apprise_server: "json://lab:SECRET_REQUEST187@example.invalid/",
                  youtube_api_key: "SECRET_REQUEST187"
                }
              )

            assert redirected_to(changed) == ~p"/settings"
          end)

        assert log =~ "SettingController.update"
        refute log =~ "SECRET_REQUEST187"
      after
        Logger.configure(level: previous_level)
      end
    end

    test "saves and redirects when data is valid", %{conn: conn} do
      update_attrs = %{
        apprise_server: "test://server",
        external_base_url: "https://pinchflat.example.com",
        yt_dlp_download_worker_concurrency: 2
      }

      conn = put(conn, ~p"/settings", setting: update_attrs)
      assert redirected_to(conn) == ~p"/settings"

      conn = get(conn, ~p"/settings")
      assert html_response(conn, 200) =~ update_attrs[:apprise_server]
      assert html_response(conn, 200) =~ update_attrs[:external_base_url]
      assert html_response(conn, 200) =~ "Download Workers"
      assert html_response(conn, 200) =~ "Base yt-dlp Config"
    end

    test "shows compose ownership when a worker env var is set", %{conn: conn} do
      System.put_env("YT_DLP_DOWNLOAD_WORKER_CONCURRENCY", "1")

      on_exit(fn -> System.delete_env("YT_DLP_DOWNLOAD_WORKER_CONCURRENCY") end)

      conn = get(conn, ~p"/settings")
      html = html_response(conn, 200)

      assert html =~ "YT_DLP_DOWNLOAD_WORKER_CONCURRENCY"
      assert html =~ "Remove that variable from your compose file"
    end

    test "re-renders the form when data is invalid", %{conn: conn} do
      conn = put(conn, ~p"/settings", setting: %{yt_dlp_update_policy: "bogus"})

      assert html_response(conn, 200) =~ "Settings"
    end

    test "kicks off a yt-dlp update when the update policy changes", %{conn: conn} do
      conn = put(conn, ~p"/settings", setting: %{yt_dlp_update_policy: "nightly"})

      assert redirected_to(conn) == ~p"/settings"
      assert_enqueued(worker: Pinchflat.YtDlp.UpdateWorker, args: %{"apply_policy" => true})
    end

    test "does not kick off a yt-dlp update when unrelated settings change", %{conn: conn} do
      conn = put(conn, ~p"/settings", setting: %{apprise_server: "test://server"})

      assert redirected_to(conn) == ~p"/settings"
      refute_enqueued(worker: Pinchflat.YtDlp.UpdateWorker)
    end

    test "marks a staged reconcile plan stale", %{conn: conn} do
      {:ok, plan} = Pinchflat.Reconciliation.create_plan(%{mode: :local, status: :ready})

      put(conn, ~p"/settings", setting: %{apprise_server: "test://server"})

      assert Pinchflat.Reconciliation.get_plan!(plan.id).status == :stale
    end
  end

  describe "download_cookies" do
    setup do
      base_dir =
        Path.join([
          System.tmp_dir!(),
          "setting_controller_test",
          Integer.to_string(:erlang.unique_integer([:positive]))
        ])

      File.mkdir_p!(base_dir)
      original = Application.get_env(:pinchflat, :extras_directory)
      Application.put_env(:pinchflat, :extras_directory, base_dir)

      on_exit(fn ->
        Application.put_env(:pinchflat, :extras_directory, original)
        File.rm_rf!(base_dir)
      end)

      :ok
    end

    test "sends the cookies file when one exists", %{conn: conn} do
      File.write!(Pinchflat.Settings.CookieFile.filepath(), "some-cookies")

      conn = get(conn, ~p"/settings/cookies")

      assert response(conn, 200) =~ "some-cookies"
    end

    test "redirects with an error when no cookies file exists", %{conn: conn} do
      conn = get(conn, ~p"/settings/cookies")

      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["error"] == "No cookies file has been uploaded"
    end
  end

  describe "download_logs" do
    test "downloads logs", %{conn: conn} do
      log_path = Path.join([System.tmp_dir!(), "pinchflat", "data", "pinchflat.log"])
      FilesystemUtils.write_p(log_path, "test log data")
      Application.put_env(:pinchflat, :log_path, log_path)

      conn = get(conn, ~p"/download_logs")

      assert response(conn, 200) =~ "test log data"

      Application.put_env(:pinchflat, :log_path, nil)
    end

    test "redirects when log file is not found", %{conn: conn} do
      conn = get(conn, ~p"/download_logs")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] == "Log file couldn't be found"
    end
  end

  describe "postgresql backups" do
    @tag :sqlite_only

    test "reports that backup creation is unavailable for SQLite", %{conn: conn} do
      conn = post(conn, ~p"/settings/backups")

      assert redirected_to(conn) == ~p"/backups"
      assert conn.assigns[:flash]["error"] =~ "unavailable when Pinchflat-ngx uses SQLite"
    end
  end

  describe "storage space protection and resume_downloads" do
    test "saves storage protection settings", %{conn: conn} do
      stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 30 * 1024 * 1024 * 1024} end)

      update_attrs = %{
        download_space_protection_enabled: true,
        download_space_protection_threshold_bytes: 21_474_836_480
      }

      conn = put(conn, ~p"/settings", setting: update_attrs)
      assert redirected_to(conn) == ~p"/settings"

      conn = get(conn, ~p"/settings")
      assert html_response(conn, 200) =~ "Storage &amp; Space Protection"
      assert Pinchflat.Settings.get!(:download_space_protection_enabled) == true
      assert Pinchflat.Settings.get!(:download_space_protection_threshold_bytes) == 21_474_836_480
    end

    test "resumes downloads when storage space is sufficient", %{conn: conn} do
      Pinchflat.Settings.set(download_space_protection_enabled: true)
      Pinchflat.Settings.set(download_space_protection_blocked: true)
      Pinchflat.Settings.set(download_space_protection_threshold_bytes: 10 * 1024 * 1024 * 1024)

      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 20 * 1024 * 1024 * 1024} end)

      conn = post(conn, ~p"/settings/resume_downloads")
      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["info"] =~ "Download protection block lifted"
      assert Pinchflat.Settings.get!(:download_space_protection_blocked) == false
    end

    test "rejects resuming downloads when storage space is below recovery threshold", %{conn: conn} do
      Pinchflat.Settings.set(download_space_protection_enabled: true)
      Pinchflat.Settings.set(download_space_protection_blocked: true)
      ten_gib = 10 * 1024 * 1024 * 1024
      Pinchflat.Settings.set(download_space_protection_threshold_bytes: ten_gib)

      # 10.2 GiB is below recovery threshold (11 GiB)
      expect(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 10 * 1024 * 1024 * 1024 + 200_000_000} end)

      conn = post(conn, ~p"/settings/resume_downloads")
      assert redirected_to(conn) == ~p"/settings"
      assert conn.assigns[:flash]["error"] =~ "still below the recovery threshold"
      assert Pinchflat.Settings.get!(:download_space_protection_blocked) == true
    end
  end
end
