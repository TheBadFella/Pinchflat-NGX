defmodule PinchflatWeb.Settings.YtDlpConfigLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings.YtDlpConfigLive
  alias Pinchflat.Settings.YtDlpConfigFile

  setup do
    base_dir =
      Path.join([System.tmp_dir!(), "yt_dlp_config_live_test", Integer.to_string(:erlang.unique_integer([:positive]))])

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
    test "shows the Empty badge when no config is present", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, YtDlpConfigLive)

      assert html =~ "Empty"
      refute html =~ "In use"
      assert html =~ "https://github.com/yt-dlp/yt-dlp#options"
      assert html =~ "yt-dlp options list"
    end

    test "shows the In use badge when a config exists", %{conn: conn} do
      YtDlpConfigFile.save("--force-ipv4\n")
      {:ok, _view, html} = live_isolated(conn, YtDlpConfigLive)

      assert html =~ "In use"
      assert html =~ "--force-ipv4"
    end
  end

  describe "saving and clearing" do
    test "saves the textarea contents", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpConfigLive)

      view
      |> element("#yt-dlp-config-form textarea")
      |> render_change(%{"contents" => "--retries 20\n"})

      html = view |> element("button", "Save Config") |> render_click()

      assert html =~ "In use"
      assert html =~ "Config saved"
      assert YtDlpConfigFile.read() == "--retries 20\n"
    end

    test "clears the file and updates the UI", %{conn: conn} do
      YtDlpConfigFile.save("--force-ipv4\n")
      {:ok, view, _html} = live_isolated(conn, YtDlpConfigLive)

      html = view |> element("button", "Clear") |> render_click()

      assert html =~ "Empty"
      refute YtDlpConfigFile.present?()
    end
  end
end
