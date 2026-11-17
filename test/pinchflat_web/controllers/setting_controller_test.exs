defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Utils.FilesystemUtils

  describe "show settings" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/settings")
      html = html_response(conn, 200)

      assert html =~ "Settings"
      assert html =~ ~s(id="setting-search")
      assert html =~ "Notification Settings"
      assert html =~ "Extractor Settings"
      assert html =~ "Cookies"
      assert html =~ "Base yt-dlp Config"
      assert html =~ "yt-dlp Plugins"
      assert html =~ "PostgreSQL Backups"
      assert html =~ ~s(href="/backups")
      refute html =~ ~s(data-settings-group="backups")
      refute html =~ ~s(id="postgres-backups")
      assert html =~ "Review PostgreSQL migration"
      assert html =~ ~s(href="/postgres_migration")
    end
  end

  describe "settings page layout" do
    test "renders section navigation, the settings search and collapsed media servers", %{conn: conn} do
      html = conn |> get(~p"/settings") |> html_response(200)

      for id <-
            ~w(settings-notifications settings-extractor database-migration settings-discovery settings-yt-dlp
               settings-codecs settings-storage media-server-settings settings-yt-dlp-plugins settings-cookies
               api-access-settings) do
        assert html =~ ~s(id="#{id}")
        assert html =~ ~s(href="##{id}")
      end

      assert html =~ ~s|x-data="settingsPage()"|
      assert html =~ ~s(aria-label="Settings in Notifications")
      refute html =~ "matchGroup"

      for title <- ["Plex Media Server", "Jellyfin", "Emby"] do
        assert html =~ ~r/<details[^>]*>\s*<summary[^>]*>.*?#{title}.*?Off.*?<\/summary>/s
      end

      refute html =~ ~r/<details[^>]*\sopen/
    end

    test "keeps every embedded LiveView reachable from the section list", %{conn: conn} do
      html = conn |> get(~p"/settings") |> html_response(200)

      for id <-
            ~w(settings-apprise settings-youtube-api-key settings-yt-dlp-version settings-yt-dlp-config
               settings-plugins settings-cookie-file settings-default-cookie-behaviour settings-share-tokens) do
        assert html =~ ~r/<div[^>]*id="#{id}"[^>]*data-setting[^>]*>\s*<div[^>]*data-phx-session/
      end
    end

    test "uses a toggle for on/off settings and a dropdown for the time format", %{conn: conn} do
      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s(id="settings-form_notification_include_video_titles-wrapper")
      assert html =~ ~s(id="cookie-health-monitoring-enabled-wrapper")
      assert html =~ ~r/<input[^>]*type="hidden"[^>]*name="setting\[time_format\]"[^>]*value="24h"/
      assert html =~ "24-hour"
      assert html =~ "12-hour"
    end

    test "opens a media server group when one of its fields has an error", %{conn: conn} do
      conn = put(conn, ~p"/settings", setting: %{jellyfin_enabled: "true", jellyfin_url: ""})
      html = html_response(conn, 200)

      assert [opened] = Regex.scan(~r/<details[^>]*\sopen[^>]*>.*?<\/summary>/s, html)
      assert hd(opened) =~ "Jellyfin"
      assert hd(opened) =~ "Refresh on"
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

  describe "codec preferences in settings" do
    setup do
      on_exit(fn ->
        Pinchflat.Settings.update_setting(Pinchflat.Settings.record(), %{
          video_codec_preference: "avc",
          audio_codec_preference: "m4a"
        })
      end)

      :ok
    end

    test "renders interpolated codec list ids and labels", %{conn: conn} do
      Pinchflat.Settings.set(video_codec_preference: "vp9,avc")
      Pinchflat.Settings.set(audio_codec_preference: "opus,m4a")

      conn = get(conn, ~p"/settings")
      html = html_response(conn, 200)

      refute html =~ "@{"
      assert html =~ ~s(for="settings-form_video_codec_preference-first")
      assert html =~ ~s(for="settings-form_audio_codec_preference-first")
      assert html =~ ~s(x-bind:id="index === 0 ? &#39;settings-form_video_codec_preference-first&#39;)
      assert html =~ "&#39; for &#39; + &#39;Video codec preferences&#39;"
      assert html =~ "&#39; for &#39; + &#39;Audio codec preferences&#39;"
    end

    test "labels the codec lists without a dangling for attribute when empty", %{conn: conn} do
      Pinchflat.Settings.set(video_codec_preference: "")
      Pinchflat.Settings.set(audio_codec_preference: "")

      html = conn |> get(~p"/settings") |> html_response(200)

      refute html =~ ~s(for="settings-form_video_codec_preference-first")
      refute html =~ ~s(for="settings-form_audio_codec_preference-first")
      assert html =~ "Video codec preferences"
      assert html =~ "Audio codec preferences"
    end

    test "saves ordered codec preferences", %{conn: conn} do
      conn =
        put(conn, ~p"/settings", %{
          setting: %{video_codec_preference: "vp9,avc,av1", audio_codec_preference: "opus,m4a"}
        })

      assert redirected_to(conn) == ~p"/settings"

      assert Pinchflat.Settings.get!(:video_codec_preference) == "vp9,avc,av1"
      assert Pinchflat.Settings.get!(:audio_codec_preference) == "opus,m4a"
    end

    test "saves codec aliases canonicalized to select values", %{conn: conn} do
      conn =
        put(conn, ~p"/settings", %{
          setting: %{video_codec_preference: "H264,VP09", audio_codec_preference: "aac,aiff"}
        })

      assert redirected_to(conn) == ~p"/settings"
      assert Pinchflat.Settings.get!(:video_codec_preference) == "avc,vp9"
      assert Pinchflat.Settings.get!(:audio_codec_preference) == "m4a,wav"
    end

    test "renders legacy stored aliases canonicalized to select values", %{conn: conn} do
      Pinchflat.Settings.set(video_codec_preference: "h264")
      Pinchflat.Settings.set(audio_codec_preference: "aac")

      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s(&quot;codec&quot;:&quot;avc&quot;)
      assert html =~ ~s(&quot;codec&quot;:&quot;m4a&quot;)
      refute html =~ ~s(&quot;codec&quot;:&quot;h264&quot;)
      refute html =~ ~s(&quot;codec&quot;:&quot;aac&quot;)
    end

    test "clears codec preferences to an empty string", %{conn: conn} do
      Pinchflat.Settings.set(video_codec_preference: "vp9,avc")
      Pinchflat.Settings.set(audio_codec_preference: "opus,m4a")

      conn = put(conn, ~p"/settings", %{setting: %{video_codec_preference: "", audio_codec_preference: ""}})

      assert redirected_to(conn) == ~p"/settings"
      assert Pinchflat.Settings.get!(:video_codec_preference) == ""
      assert Pinchflat.Settings.get!(:audio_codec_preference) == ""
    end

    test "rejects an unknown codec and keeps the draft", %{conn: conn} do
      conn = put(conn, ~p"/settings", %{setting: %{video_codec_preference: "vp9,boguscodec"}})

      html = html_response(conn, 200)
      assert html =~ "unsupported codec"
      assert html =~ "boguscodec"
      assert Pinchflat.Settings.get!(:video_codec_preference) != "vp9,boguscodec"
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
