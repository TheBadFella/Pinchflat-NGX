defmodule Pinchflat.YtDlp.PluginDirectoryTest do
  use Pinchflat.DataCase

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
    original = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
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
end
