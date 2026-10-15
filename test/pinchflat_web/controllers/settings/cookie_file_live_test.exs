defmodule PinchflatWeb.Settings.CookieFileLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings
  alias Pinchflat.Settings.CookieFile
  alias Pinchflat.Settings.CookieFileLive

  setup do
    base_dir =
      Path.join([
        System.tmp_dir!(),
        "cookie_live_test",
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

  describe "initial rendering" do
    test "shows the Empty badge and Not Configured health status when no cookies are present", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, CookieFileLive)

      assert html =~ "Empty"
      refute html =~ "Populated"
      assert html =~ "Cookie Health Status"
      assert html =~ "Not Configured"
      assert html =~ "Test Now"
      assert html =~ "Enable Automatic Periodic Health Monitoring"
    end

    test "shows the Populated badge, download and clear when cookies exist", %{conn: conn} do
      File.write!(CookieFile.filepath(), "some-cookies")
      {:ok, _view, html} = live_isolated(conn, CookieFileLive)

      assert html =~ "Populated"
      assert html =~ "Download"
      assert html =~ "Clear"
    end
  end

  describe "clearing cookies" do
    test "blanks the file and updates the UI", %{conn: conn} do
      File.write!(CookieFile.filepath(), "some-cookies")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("button", "Clear") |> render_click()

      assert html =~ "Empty"
      assert html =~ "Not Configured"
      refute CookieFile.present?()
    end
  end

  describe "validating cookies" do
    test "reports a valid file", %{conn: conn} do
      File.write!(CookieFile.filepath(), ".youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("[phx-click=validate_cookies]") |> render_click()

      assert html =~ "hero-check"
    end

    test "reports an invalid file", %{conn: conn} do
      File.write!(CookieFile.filepath(), "not a cookie file")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("[phx-click=validate_cookies]") |> render_click()

      assert html =~ "hero-x-mark"
    end
  end

  describe "uploading cookies" do
    test "saves the uploaded file and marks it populated and updates health status", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      cookies =
        file_input(view, "#cookie-file-form", :cookies, [
          %{
            name: "cookies.txt",
            content: ".youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue",
            type: "text/plain"
          }
        ])

      render_upload(cookies, "cookies.txt")
      html = view |> element("#cookie-file-form") |> render_submit()

      assert html =~ "Populated"
      assert CookieFile.present?()
      assert html =~ "Unverified Auth"
    end
  end

  describe "monitoring configuration form" do
    test "saves monitoring interval and enabled state", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html =
        view
        |> form("form[phx-submit=save_monitoring_config]", %{
          "cookie_health_monitoring_enabled" => "true",
          "cookie_health_check_interval_hours" => "12",
          "cookie_health_canary_url" => "https://www.youtube.com/watch?v=sample123"
        })
        |> render_submit()

      assert html =~ "Saved!"
      setting = Settings.record()
      assert setting.cookie_health_monitoring_enabled == true
      assert setting.cookie_health_check_interval_hours == 12
      assert setting.cookie_health_canary_url == "https://www.youtube.com/watch?v=sample123"
    end

    test "shows validation error for invalid canary URL", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html =
        view
        |> form("form[phx-submit=save_monitoring_config]", %{
          "cookie_health_monitoring_enabled" => "true",
          "cookie_health_check_interval_hours" => "12",
          "cookie_health_canary_url" => "https://invalid-site.example.com/video"
        })
        |> render_submit()

      assert html =~ "must be a valid YouTube video or shorts URL"
    end
  end
end
