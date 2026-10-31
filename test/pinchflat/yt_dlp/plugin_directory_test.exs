defmodule Pinchflat.YtDlp.PluginDirectoryTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.PluginFixtures

  alias Pinchflat.YtDlp.PluginDirectory

  setup do
    base_dir =
      Path.join([
        System.tmp_dir!(),
        "plugin_directory_test",
        Integer.to_string(:erlang.unique_integer([:positive]))
      ])

    File.mkdir_p!(base_dir)
    original_extras = Application.get_env(:pinchflat, :extras_directory)
    original_allowlist = Application.get_env(:pinchflat, :yt_dlp_plugin_url_allowlist)
    original_allow_private = Application.get_env(:pinchflat, :yt_dlp_plugin_url_allow_private)

    Application.put_env(:pinchflat, :extras_directory, base_dir)
    Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["example.com"])
    Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, false)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original_extras)
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, original_allowlist)
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, original_allow_private)
      File.rm_rf!(base_dir)
    end)

    :ok
  end

  describe "path/0" do
    test "returns the managed plugin directory under extras" do
      extras = Application.get_env(:pinchflat, :extras_directory)

      assert PluginDirectory.path() == Path.join(extras, "yt-dlp-plugins")
    end
  end

  describe "ensure/0" do
    test "creates the managed directory" do
      refute File.exists?(PluginDirectory.path())

      assert :ok = PluginDirectory.ensure()
      assert File.dir?(PluginDirectory.path())
    end
  end

  describe "options/0" do
    test "returns no options when the directory is missing" do
      assert PluginDirectory.options() == []
    end

    test "returns no options when the directory is empty" do
      File.mkdir_p!(PluginDirectory.path())

      assert PluginDirectory.options() == []
    end

    test "ignores hidden files" do
      File.mkdir_p!(PluginDirectory.path())
      File.write!(Path.join(PluginDirectory.path(), ".keep"), "")

      assert PluginDirectory.options() == []
    end

    test "returns the plugin directory when a folder package exists" do
      File.mkdir_p!(Path.join([PluginDirectory.path(), "sample", "yt_dlp_plugins"]))

      assert PluginDirectory.options() == [plugin_dirs: PluginDirectory.path()]
    end

    test "returns the plugin directory when an archive exists" do
      File.mkdir_p!(PluginDirectory.path())
      File.write!(Path.join(PluginDirectory.path(), "sample.zip"), "zipdata")

      assert PluginDirectory.options() == [plugin_dirs: PluginDirectory.path()]
    end
  end

  describe "install_archive/2" do
    test "stores a valid archive byte-for-byte and lists it" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
      assert entry.name == "sample"
      assert entry.filename == "sample.zip"
      assert entry.kind == :archive
      assert File.read!(entry.path) == File.read!(source)
      assert [entry] == PluginDirectory.list()
    end

    test "accepts whl and egg archives" do
      for extension <- [".whl", ".egg"] do
        source = plugin_zip_file_fixture()
        on_exit(fn -> File.rm(source) end)

        assert {:ok, entry} = PluginDirectory.install_archive(source, filename: "plugin#{extension}")
        assert entry.filename == "plugin#{extension}"
      end
    end

    test "rejects unsupported extensions" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:error, :unsupported_extension} =
               PluginDirectory.install_archive(source, filename: "plugin.tar.gz")

      refute File.exists?(Path.join(PluginDirectory.path(), "plugin.tar.gz"))
    end

    test "rejects invalid zip data" do
      path = Path.join(System.tmp_dir!(), "invalid-plugin-#{System.unique_integer([:positive])}.zip")
      File.write!(path, "not a zip")
      on_exit(fn -> File.rm(path) end)

      assert {:error, :invalid_archive} = PluginDirectory.install_archive(path)
    end

    test "rejects an archive without the plugin namespace" do
      source = plugin_zip_file_fixture([{"README.md", "nothing"}])
      on_exit(fn -> File.rm(source) end)

      assert {:error, :missing_plugin_namespace} =
               PluginDirectory.install_archive(source, filename: "sample.zip")
    end

    test "rejects a wrapper-directory archive" do
      source = plugin_zip_file_fixture([{"sample-main/yt_dlp_plugins/extractor/sample.py", "..."}])
      on_exit(fn -> File.rm(source) end)

      assert {:error, :wrapper_directory} = PluginDirectory.install_archive(source, filename: "sample.zip")
    end

    test "rejects unsafe archive entry names" do
      source =
        plugin_zip_file_fixture([
          {"yt_dlp_plugins/extractor/sample.py", "..."},
          {"../evil.py", "..."}
        ])

      on_exit(fn -> File.rm(source) end)

      assert {:error, :unsafe_archive} = PluginDirectory.install_archive(source, filename: "sample.zip")
    end

    test "rejects an archive larger than max_bytes/0" do
      path = Path.join(System.tmp_dir!(), "large-plugin-#{System.unique_integer([:positive])}.zip")
      File.write!(path, :binary.copy(<<0>>, PluginDirectory.max_bytes() + 1))
      on_exit(fn -> File.rm(path) end)

      assert {:error, :too_large} = PluginDirectory.install_archive(path)
    end

    test "rejects an existing filename" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
      assert {:error, :already_installed} = PluginDirectory.install_archive(source, filename: "sample.zip")
    end

    test "replaces an existing archive when replace is true" do
      first = plugin_zip_file_fixture([{"yt_dlp_plugins/extractor/sample.py", "first"}])
      second = plugin_zip_file_fixture([{"yt_dlp_plugins/extractor/sample.py", "second"}])
      on_exit(fn -> File.rm(first) end)
      on_exit(fn -> File.rm(second) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(first, filename: "sample.zip")
      assert {:ok, entry} = PluginDirectory.install_archive(second, filename: "sample.zip", replace: true)

      assert File.read!(entry.path) == File.read!(second)
    end

    test "rejects unsafe destination filenames" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:error, :invalid_name} = PluginDirectory.install_archive(source, filename: "../sample.zip")
    end
  end

  describe "list/0" do
    test "returns no entries when the directory is missing" do
      assert PluginDirectory.list() == []
    end

    test "returns folder and archive entries sorted by filename" do
      File.mkdir_p!(Path.join([PluginDirectory.path(), "folder", "yt_dlp_plugins"]))
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "zeta.zip")

      entries = PluginDirectory.list()

      assert Enum.map(entries, & &1.filename) == ["folder", "zeta.zip"]
      assert Enum.map(entries, & &1.kind) == [:directory, :archive]
      assert Enum.all?(entries, &Map.has_key?(&1, :source_url))
    end

    test "tolerates corrupt metadata" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
      File.write!(Path.join(PluginDirectory.path(), ".pinchflat-plugins.json"), "{")

      assert [%{filename: "sample.zip", source_url: nil}] = PluginDirectory.list()
    end

    test "tolerates non-map plugin metadata" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")

      File.write!(
        Path.join(PluginDirectory.path(), ".pinchflat-plugins.json"),
        Jason.encode!(%{"plugins" => %{"sample.zip" => 5}})
      )

      assert [%{filename: "sample.zip", source_url: nil}] = PluginDirectory.list()
      assert {:error, :no_source_url} = PluginDirectory.update_from_source("sample.zip")
    end
  end

  describe "remove/1" do
    test "removes an archive and its metadata" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
      assert :ok = PluginDirectory.remove("sample.zip")
      refute File.exists?(Path.join(PluginDirectory.path(), "sample.zip"))
      assert PluginDirectory.list() == []
    end

    test "removes a folder" do
      folder = Path.join([PluginDirectory.path(), "sample", "yt_dlp_plugins"])
      File.mkdir_p!(folder)

      assert :ok = PluginDirectory.remove("sample")
      refute File.exists?(Path.dirname(folder))
    end

    test "rejects path traversal and hidden names" do
      assert {:error, :invalid_name} = PluginDirectory.remove("../evil")
      assert {:error, :invalid_name} = PluginDirectory.remove("nested/sample.zip")
      assert {:error, :invalid_name} = PluginDirectory.remove(".pinchflat-plugins.json")
    end

    test "returns not_found for a missing entry" do
      assert {:error, :not_found} = PluginDirectory.remove("missing.zip")
    end
  end

  describe "plugin logging" do
    test "logs successful installs" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
          end)
        end)

      assert log =~ "[yt-dlp plugins] Install succeeded for \"sample.zip\""
    end

    test "logs failed installs" do
      path = Path.join(System.tmp_dir!(), "invalid-log-plugin-#{System.unique_integer([:positive])}.zip")
      File.write!(path, "not a zip")
      on_exit(fn -> File.rm(path) end)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert {:error, :invalid_archive} = PluginDirectory.install_archive(path)
          end)
        end)

      assert log =~ "[yt-dlp plugins] Install failed"
    end

    test "logs config saves" do
      install_sample_plugin()

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")
          end)
        end)

      assert log =~ "[yt-dlp plugins] Config save succeeded for \"sample.zip\""
    end
  end

  describe "documentation/1" do
    test "returns README contents for a folder plugin" do
      plugin_root = Path.join(PluginDirectory.path(), "sample")
      File.mkdir_p!(Path.join(plugin_root, "yt_dlp_plugins"))
      File.write!(Path.join(plugin_root, "README.md"), "# Sample\nUse --use-postprocessor SamplePP")

      assert {:ok, docs} = PluginDirectory.documentation("sample")
      assert docs =~ "Use --use-postprocessor SamplePP"
    end

    test "returns README contents from an installed archive" do
      source =
        plugin_zip_file_fixture([
          {"yt_dlp_plugins/extractor/sample.py", "class SampleIE: pass"},
          {"README.md", "# Sample\nUse --extractor-args 'sample:key=value'"}
        ])

      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
      assert {:ok, docs} = PluginDirectory.documentation("sample.zip")
      assert docs =~ "--extractor-args"
    end

    test "returns nil when the package has no README" do
      install_sample_plugin()

      assert {:ok, nil} = PluginDirectory.documentation("sample.zip")
    end

    test "rejects missing and invalid plugin names" do
      assert {:error, :not_found} = PluginDirectory.documentation("missing.zip")
      assert {:error, :invalid_name} = PluginDirectory.documentation("../sample.zip")
    end
  end

  describe "plugin configuration" do
    test "ensure/0 creates the plugin config directory" do
      File.rm_rf!(PluginDirectory.config_directory())

      refute File.exists?(PluginDirectory.config_directory())

      assert :ok = PluginDirectory.ensure()
      assert File.dir?(PluginDirectory.config_directory())
    end

    test "save_config/2 writes, read_config/1 reads, and list/0 marks configuration" do
      install_sample_plugin()
      config = "--extractor-args 'sample:key=value'\n"

      assert :ok = PluginDirectory.save_config("sample.zip", config)
      assert {:ok, ^config} = PluginDirectory.read_config("sample.zip")
      assert [%{filename: "sample.zip", has_config: true}] = PluginDirectory.list()
    end

    test "save_config/2 with blank contents clears the config" do
      install_sample_plugin()

      assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")
      assert :ok = PluginDirectory.save_config("sample.zip", " \n")
      assert {:ok, ""} = PluginDirectory.read_config("sample.zip")
      assert [%{filename: "sample.zip", has_config: false}] = PluginDirectory.list()
    end

    test "clear_config/1 removes the config" do
      install_sample_plugin()

      assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")
      assert :ok = PluginDirectory.clear_config("sample.zip")
      assert {:ok, ""} = PluginDirectory.read_config("sample.zip")
      assert [%{filename: "sample.zip", has_config: false}] = PluginDirectory.list()
    end

    test "remove/1 deletes the plugin config" do
      install_sample_plugin()

      assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")
      assert {:ok, config_path} = PluginDirectory.config_path("sample.zip")
      assert :ok = PluginDirectory.remove("sample.zip")
      refute File.exists?(config_path)
    end

    test "config_locations/0 includes only configs for installed plugins" do
      install_sample_plugin()

      assert :ok = PluginDirectory.save_config("sample.zip", "--force-ipv4\n")
      assert {:ok, config_path} = PluginDirectory.config_path("sample.zip")
      assert PluginDirectory.config_locations() == [config_locations: config_path]

      File.write!(Path.join(PluginDirectory.config_directory(), "missing.zip.conf"), "--force-ipv4\n")

      assert PluginDirectory.config_locations() == [config_locations: config_path]
    end

    test "config_locations/0 returns no options when no configs exist" do
      install_sample_plugin()

      assert PluginDirectory.config_locations() == []
    end

    test "save_config/2 rejects invalid names, missing plugins, and oversized contents" do
      install_sample_plugin()

      assert {:error, :invalid_name} = PluginDirectory.save_config("../sample.zip", "--force-ipv4")
      assert {:error, :not_found} = PluginDirectory.save_config("missing.zip", "--force-ipv4")

      too_large = String.duplicate("a", PluginDirectory.max_config_bytes() + 1)
      assert {:error, :too_large} = PluginDirectory.save_config("sample.zip", too_large)
    end
  end

  describe "install_from_url/2" do
    test "stores a fetched archive and records its source URL" do
      zip = plugin_zip_fixture()

      expect(HTTPClientMock, :get_with_response, fn url, _headers, opts ->
        assert url == "https://example.com/sample.zip"
        assert opts[:connect_address] == {93, 184, 216, 34}

        {:ok, %{status: 200, headers: [], body: zip}}
      end)

      assert {:ok, entry} =
               PluginDirectory.install_from_url("https://example.com/sample.zip", dns_resolver: public_resolver())

      assert entry.filename == "sample.zip"
      assert entry.source_url == "https://example.com/sample.zip"
      assert File.read!(entry.path) == zip
    end

    test "rejects a URL without a supported archive extension before fetching" do
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      assert {:error, :unsupported_extension} =
               PluginDirectory.install_from_url("https://example.com/plugin", dns_resolver: public_resolver())
    end

    test "propagates fetch errors and writes nothing" do
      expect(HTTPClientMock, :get_with_response, fn _, _, _ ->
        {:ok, %{status: 404, headers: [], body: ""}}
      end)

      assert {:error, {:http_status, 404}} =
               PluginDirectory.install_from_url("https://example.com/sample.zip", dns_resolver: public_resolver())

      assert PluginDirectory.list() == []
    end

    test "rejects an invalid archive returned by the URL" do
      expect(HTTPClientMock, :get_with_response, fn _, _, _ ->
        {:ok, %{status: 200, headers: [], body: "not a zip"}}
      end)

      assert {:error, :invalid_archive} =
               PluginDirectory.install_from_url("https://example.com/sample.zip", dns_resolver: public_resolver())

      assert PluginDirectory.list() == []
    end
  end

  describe "update_from_source/2" do
    test "replaces a URL-installed archive and updates metadata" do
      first = plugin_zip_fixture([{"yt_dlp_plugins/extractor/sample.py", "first"}])
      second = plugin_zip_fixture([{"yt_dlp_plugins/extractor/sample.py", "second"}])

      Process.put(:plugin_update_fetches, 0)

      stub(HTTPClientMock, :get_with_response, fn _url, _headers, _opts ->
        calls = Process.get(:plugin_update_fetches, 0)
        Process.put(:plugin_update_fetches, calls + 1)
        body = if calls == 0, do: first, else: second

        {:ok, %{status: 200, headers: [], body: body}}
      end)

      assert {:ok, _entry} =
               PluginDirectory.install_from_url("https://example.com/sample.zip", dns_resolver: public_resolver())

      assert {:ok, entry} = PluginDirectory.update_from_source("sample.zip", dns_resolver: public_resolver())
      assert File.read!(entry.path) == second
      assert entry.source_url == "https://example.com/sample.zip"
    end

    test "keeps the old archive when the new archive is invalid" do
      first = plugin_zip_fixture()

      Process.put(:plugin_update_fetches, 0)

      stub(HTTPClientMock, :get_with_response, fn _url, _headers, _opts ->
        calls = Process.get(:plugin_update_fetches, 0)
        Process.put(:plugin_update_fetches, calls + 1)
        body = if calls == 0, do: first, else: "not a zip"

        {:ok, %{status: 200, headers: [], body: body}}
      end)

      assert {:ok, entry} =
               PluginDirectory.install_from_url("https://example.com/sample.zip", dns_resolver: public_resolver())

      assert {:error, :invalid_archive} =
               PluginDirectory.update_from_source("sample.zip", dns_resolver: public_resolver())

      assert File.read!(entry.path) == first
      assert [%{filename: "sample.zip", source_url: "https://example.com/sample.zip"}] = PluginDirectory.list()
    end

    test "returns no_source_url for uploads and folders" do
      source = plugin_zip_file_fixture()
      on_exit(fn -> File.rm(source) end)

      assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
      assert {:error, :no_source_url} = PluginDirectory.update_from_source("sample.zip")

      File.mkdir_p!(Path.join([PluginDirectory.path(), "folder", "yt_dlp_plugins"]))
      assert {:error, :no_source_url} = PluginDirectory.update_from_source("folder")
    end

    test "returns not_found when the plugin was removed" do
      assert {:error, :not_found} = PluginDirectory.update_from_source("missing.zip")
    end
  end

  defp install_sample_plugin do
    source = plugin_zip_file_fixture()
    on_exit(fn -> File.rm(source) end)

    assert {:ok, _entry} = PluginDirectory.install_archive(source, filename: "sample.zip")
  end

  defp with_debug_logs(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end

  defp public_resolver(ip \\ {93, 184, 216, 34}) do
    fn _host -> {:ok, [ip]} end
  end
end
