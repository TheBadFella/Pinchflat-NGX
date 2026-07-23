defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Utils.FilesystemUtils

  describe "show settings" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200) =~ "Settings"
    end
  end

  describe "update settings" do
    test "saves and redirects when data is valid", %{conn: conn} do
      update_attrs = %{apprise_server: "test://server", external_base_url: "https://pinchflat.example.com"}

      conn = put(conn, ~p"/settings", setting: update_attrs)
      assert redirected_to(conn) == ~p"/settings"

      conn = get(conn, ~p"/settings")
      assert html_response(conn, 200) =~ update_attrs[:apprise_server]
      assert html_response(conn, 200) =~ update_attrs[:external_base_url]
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
>>>>>>> ad2a66e (feat: relocate and true up downloaded files after settings changes, without re-downloading)
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
end
