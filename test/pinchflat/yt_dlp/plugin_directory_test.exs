defmodule Pinchflat.YtDlp.PluginDirectoryTest do
  use Pinchflat.DataCase

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
end
