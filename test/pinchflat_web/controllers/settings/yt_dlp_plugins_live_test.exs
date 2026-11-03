defmodule PinchflatWeb.Settings.YtDlpPluginsLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.PluginFixtures

  alias Pinchflat.Settings.YtDlpPluginsLive
  alias Pinchflat.YtDlp.PluginDirectory

  setup do
    base_dir =
      Path.join([
        System.tmp_dir!(),
        "yt_dlp_plugins_live_test",
        Integer.to_string(:erlang.unique_integer([:positive]))
      ])

    File.mkdir_p!(base_dir)

    originals = %{
      extras_directory: Application.get_env(:pinchflat, :extras_directory),
      allowlist: Application.get_env(:pinchflat, :yt_dlp_plugin_url_allowlist),
      resolver: Application.get_env(:pinchflat, :yt_dlp_plugin_url_dns_resolver),
      allow_private: Application.get_env(:pinchflat, :yt_dlp_plugin_url_allow_private)
    }

    Application.put_env(:pinchflat, :extras_directory, base_dir)
    Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["example.com"])

    Application.put_env(:pinchflat, :yt_dlp_plugin_url_dns_resolver, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, false)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, originals.extras_directory)
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, originals.allowlist)
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_dns_resolver, originals.resolver)
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, originals.allow_private)
      File.rm_rf!(base_dir)
    end)

    :ok
  end

  describe "initial rendering" do
    test "shows the empty state, safety warning, and install controls", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, YtDlpPluginsLive)

      assert html =~ "yt-dlp Plugins"
      assert html =~ "No plugins installed"
      assert html =~ "arbitrary Python code"
      assert html =~ "example.com"
      assert html =~ PluginDirectory.path()
      assert has_element?(view, "#plugin-upload-form")
      assert has_element?(view, "#plugin-url-form")
    end

    test "filters the file picker to plugin archive extensions", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      assert has_element?(view, ~s(#plugin-upload-form input[type="file"][accept=".zip,.whl,.egg"]))
    end
  end

  describe "uploading plugins" do
    test "stores a valid archive and lists it", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      zip = plugin_zip_fixture()

      upload =
        file_input(view, "#plugin-upload-form", :plugin, [
          %{name: "sample.zip", content: zip, type: "application/zip"}
        ])

      render_upload(upload, "sample.zip")
      html = view |> element("#plugin-upload-form") |> render_submit()

      assert html =~ "Plugin installed"
      assert html =~ "sample"
      assert html =~ "Remove"
      assert File.exists?(Path.join(PluginDirectory.path(), "sample.zip"))
    end

    test "rejects an invalid archive and writes nothing", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      zip = plugin_zip_fixture([{"README.md", "nothing"}])

      upload =
        file_input(view, "#plugin-upload-form", :plugin, [
          %{name: "bad.zip", content: zip, type: "application/zip"}
        ])

      render_upload(upload, "bad.zip")
      html = view |> element("#plugin-upload-form") |> render_submit()

      assert html =~ "does not contain yt_dlp_plugins"
      refute File.exists?(Path.join(PluginDirectory.path(), "bad.zip"))
    end

    test "rejects an unsupported upload type", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      upload =
        file_input(view, "#plugin-upload-form", :plugin, [
          %{name: "notes.txt", content: "hello", type: "text/plain"}
        ])

      render_upload(upload, "notes.txt")
      html = view |> element("#plugin-upload-form") |> render_submit()

      assert html =~ "Only .zip, .whl, and .egg plugin archives are supported"
      refute File.exists?(Path.join(PluginDirectory.path(), "notes.txt"))
    end
  end

  describe "removing plugins" do
    test "removes an installed plugin", %{conn: conn} do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)
      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      html = view |> element("button", "Remove") |> render_click()

      assert html =~ "Plugin removed"
      assert html =~ "No plugins installed"
      refute File.exists?(Path.join(PluginDirectory.path(), "sample.zip"))
    end
  end

  describe "plugin configuration" do
    test "shows a Config button on each plugin row", %{conn: conn} do
      install_sample_plugin()

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      assert has_element?(view, ~s(button[phx-click="open_config"][phx-value-filename="sample.zip"]))
    end

    test "opens the modal with existing config", %{conn: conn} do
      install_sample_plugin()
      assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()

      assert has_element?(view, "#plugin-config-modal")
      assert render(view) =~ "--force-ipv4"
    end

    test "shows bundled documentation in the config modal", %{conn: conn} do
      source =
        plugin_zip_file_fixture([
          {"yt_dlp_plugins/extractor/sample.py", "class SampleIE: pass"},
          {"README.md", "# Sample plugin\nUse --use-postprocessor SamplePP"}
        ])

      on_exit(fn -> File.rm(source) end)
      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()

      html = render(view)
      assert html =~ "Bundled plugin documentation"
      assert html =~ "Use --use-postprocessor SamplePP"
    end

    test "explains when a plugin package has no README", %{conn: conn} do
      install_sample_plugin()

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()

      html = render(view)
      assert html =~ "has no README, or its README is too large to display"
      assert html =~ "do not expose a config schema"
    end

    test "saves config and marks the plugin configured", %{conn: conn} do
      install_sample_plugin()

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()

      html =
        view
        |> element("#plugin-config-form")
        |> render_submit(%{"filename" => "sample.zip", "contents" => "--force-ipv4\n"})

      assert html =~ "Plugin config saved"
      assert html =~ "Configured"
      refute has_element?(view, "#plugin-config-modal")
      assert {:ok, "--force-ipv4\n"} = PluginDirectory.read_config("sample.zip")
    end

    test "cancels without writing", %{conn: conn} do
      install_sample_plugin()

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()
      view |> element(~s(button[phx-click="close_config"]), "Cancel") |> render_click()

      refute has_element?(view, "#plugin-config-modal")
      assert {:ok, ""} = PluginDirectory.read_config("sample.zip")
    end

    test "clears an existing config", %{conn: conn} do
      install_sample_plugin()
      assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()

      html = view |> element(~s(button[phx-click="clear_config"]), "Clear") |> render_click()

      assert html =~ "Plugin config cleared"
      refute has_element?(view, "#plugin-config-modal")
      assert {:ok, ""} = PluginDirectory.read_config("sample.zip")
      refute html =~ "Configured"
    end

    test "rejects an oversized config", %{conn: conn} do
      install_sample_plugin()
      too_large = String.duplicate("a", PluginDirectory.max_config_bytes() + 1)

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)
      view |> element(~s(button[phx-click="open_config"]), "Config") |> render_click()

      html =
        view
        |> element("#plugin-config-form")
        |> render_submit(%{"filename" => "sample.zip", "contents" => too_large})

      assert html =~ "Config is too large"
      assert has_element?(view, "#plugin-config-modal")
      assert {:ok, ""} = PluginDirectory.read_config("sample.zip")
    end
  end

  describe "installing from a URL" do
    test "stores the archive and records its source URL", %{conn: conn} do
      zip = plugin_zip_fixture()

      expect(HTTPClientMock, :get_with_response, 1, fn url, _headers, _opts ->
        assert url == "https://example.com/sample.zip"

        {:ok, %{status: 200, headers: [], body: zip}}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      html =
        view
        |> element("#plugin-url-form")
        |> render_submit(%{"url" => "https://example.com/sample.zip"})

      assert html =~ "Plugin installed from URL"
      assert html =~ "https://example.com/sample.zip"
      assert html =~ "Update"
      assert File.exists?(Path.join(PluginDirectory.path(), "sample.zip"))
    end

    test "shows an error and writes nothing when the URL fails", %{conn: conn} do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 404, headers: [], body: ""}}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      html =
        view
        |> element("#plugin-url-form")
        |> render_submit(%{"url" => "https://example.com/sample.zip"})

      assert html =~ "HTTP 404"
      assert html =~ "No plugins installed"
    end

    test "clears a previous success notice when a later install fails", %{conn: conn} do
      zip = plugin_zip_fixture()

      expect(HTTPClientMock, :get_with_response, 2, fn url, _headers, _opts ->
        if String.ends_with?(url, "sample.zip") do
          {:ok, %{status: 200, headers: [], body: zip}}
        else
          {:ok, %{status: 404, headers: [], body: ""}}
        end
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      view
      |> element("#plugin-url-form")
      |> render_submit(%{"url" => "https://example.com/sample.zip"})

      html =
        view
        |> element("#plugin-url-form")
        |> render_submit(%{"url" => "https://example.com/other.zip"})

      refute html =~ "Plugin installed from URL"
      assert html =~ "HTTP 404"
    end
  end

  describe "updating URL-installed plugins" do
    test "replaces the archive", %{conn: conn} do
      first = plugin_zip_file_fixture([{"yt_dlp_plugins/extractor/sample.py", "first"}])
      second = plugin_zip_fixture([{"yt_dlp_plugins/extractor/sample.py", "second"}])
      on_exit(fn -> File.rm(first) end)

      assert {:ok, _entry} =
               PluginDirectory.install_archive(first,
                 filename: "sample.zip",
                 source_url: "https://example.com/sample.zip"
               )

      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 200, headers: [], body: second}}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      html = view |> element("button", "Update") |> render_click()

      assert html =~ "Plugin updated"
      assert File.read!(Path.join(PluginDirectory.path(), "sample.zip")) == second
    end

    test "keeps the old archive when the update fails", %{conn: conn} do
      first = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(first) end)

      assert {:ok, _entry} =
               PluginDirectory.install_archive(first,
                 filename: "sample.zip",
                 source_url: "https://example.com/sample.zip"
               )

      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 200, headers: [], body: "not a zip"}}
      end)

      {:ok, view, _html} = live_isolated(conn, YtDlpPluginsLive)

      html = view |> element("button", "Update") |> render_click()

      assert html =~ "not a valid plugin archive"
      assert File.read!(Path.join(PluginDirectory.path(), "sample.zip")) == File.read!(first)
    end
  end

  defp install_sample_plugin do
    source = plugin_zip_file_fixture()
    on_exit(fn -> File.rm(source) end)

    assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
  end
end
