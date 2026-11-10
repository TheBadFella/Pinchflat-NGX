defmodule Pinchflat.Settings.ScopedYtDlpConfigFileTest do
  use Pinchflat.DataCase, async: false

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Settings.YtDlpConfigFile
  alias Pinchflat.YtDlp.PluginDirectory

  defmodule FailingFS do
    @moduledoc false

    def mkdir_p(path), do: fail_or(:mkdir_p, fn -> File.mkdir_p(path) end)
    def write(path, contents, opts), do: fail_or(:write, fn -> File.write(path, contents, opts) end)
    def rename(source, destination), do: fail_or(:rename, fn -> File.rename(source, destination) end)
    def rm(path), do: fail_or(:rm, fn -> File.rm(path) end)
    def read(path), do: fail_or(:read, fn -> File.read(path) end)
    def lstat(path), do: fail_or(:lstat, fn -> File.lstat(path) end)
    def exists?(path), do: fail_or(:exists?, fn -> File.exists?(path) end)

    defp fail_or(operation, callback) do
      if Application.get_env(:pinchflat, :test_failing_fs_op) == operation do
        {:error, :eacces}
      else
        callback.()
      end
    end
  end

  defmodule BlockingRenameFS do
    @moduledoc false

    def mkdir_p(path), do: File.mkdir_p(path)
    def write(path, contents, opts), do: File.write(path, contents, opts)
    def rm(path), do: File.rm(path)
    def read(path), do: File.read(path)
    def lstat(path), do: File.lstat(path)
    def exists?(path), do: File.exists?(path)

    def rename(source, destination) do
      case Application.get_env(:pinchflat, :test_blocking_rename_pid) do
        pid when is_pid(pid) ->
          send(pid, {:rename_started, self()})

          receive do
            :continue_rename -> File.rename(source, destination)
          after
            5_000 -> {:error, :timeout}
          end

        _ ->
          File.rename(source, destination)
      end
    end
  end

  setup do
    base_dir =
      Path.join([
        System.tmp_dir!(),
        "scoped_yt_dlp_config_test",
        Integer.to_string(:erlang.unique_integer([:positive]))
      ])

    File.mkdir_p!(base_dir)
    original_extras = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original_extras)
      Application.delete_env(:pinchflat, :yt_dlp_config_file_fs)
      Application.delete_env(:pinchflat, :test_failing_fs_op)
      Application.delete_env(:pinchflat, :test_blocking_rename_pid)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir}
  end

  defp config_dir(base_dir), do: Path.join(base_dir, "yt-dlp-configs")
  defp config_file(base_dir, filename), do: Path.join(config_dir(base_dir), filename)

  defp write_config!(base_dir, filename, contents) do
    File.mkdir_p!(config_dir(base_dir))
    File.write!(config_file(base_dir, filename), contents)
  end

  describe "F01: each scope reads only its own file" do
    test "base, profile, source and item contents stay isolated", %{base_dir: base_dir} do
      write_config!(base_dir, "base-config.txt", "--base\n")
      write_config!(base_dir, "media-profile-1-config.txt", "--profile\n")
      write_config!(base_dir, "source-2-config.txt", "--source\n")
      write_config!(base_dir, "media-item-3-config.txt", "--item\n")

      assert YtDlpConfigFile.read() == "--base\n"
      assert {:ok, %{contents: "--profile\n"}} = YtDlpConfigFile.read_scope(:profile, 1)
      assert {:ok, %{contents: "--source\n"}} = YtDlpConfigFile.read_scope(:source, 2)
      assert {:ok, %{contents: "--item\n"}} = YtDlpConfigFile.read_scope(:media_item, 3)
    end
  end

  describe "F02: exact contents round-trip" do
    test "preserves multiline Unicode, comments, quotes, backticks, dollars and CRLF", %{base_dir: base_dir} do
      contents =
        "# коммент\r\n--retries 20\n--add-metadata\n--exec \"echo $HOME\"\n`literal`\r\n$not_shell\n"

      assert :ok = YtDlpConfigFile.save_scope(:source, 7, contents, :missing)
      assert {:ok, %{contents: ^contents}} = YtDlpConfigFile.read_scope(:source, 7)
      assert File.read!(config_file(base_dir, "source-7-config.txt")) == contents
    end
  end

  describe "F03: server-derived paths and save/reload" do
    test "writes the exact path for every supported scope", %{base_dir: base_dir} do
      scopes = [
        {:profile, 11, "media-profile-11-config.txt"},
        {:source, 12, "source-12-config.txt"},
        {:media_item, 13, "media-item-13-config.txt"}
      ]

      for {scope, id, filename} <- scopes do
        assert {:ok, path} = YtDlpConfigFile.scope_path(scope, id)
        assert path == config_file(base_dir, filename)
        assert {:ok, %{version: :missing}} = YtDlpConfigFile.read_scope(scope, id)

        assert :ok = YtDlpConfigFile.save_scope(scope, id, "one\n", :missing)
        assert File.read!(path) == "one\n"

        assert {:ok, %{contents: "one\n", version: version}} = YtDlpConfigFile.read_scope(scope, id)
        assert :ok = YtDlpConfigFile.save_scope(scope, id, "two\n", version)
        assert {:ok, %{contents: "two\n"}} = YtDlpConfigFile.read_scope(scope, id)
      end
    end
  end

  describe "F04: omitted, clear and isolation" do
    test "clear affects only the selected scope and keeps the file on disk", %{base_dir: base_dir} do
      assert :ok = YtDlpConfigFile.save_scope(:source, 1, "--source\n", :missing)
      assert :ok = YtDlpConfigFile.save_scope(:profile, 1, "--profile\n", :missing)

      assert :ok = YtDlpConfigFile.clear_scope(:source, 1, :any)

      assert {:ok, %{contents: "", present?: false}} = YtDlpConfigFile.read_scope(:source, 1)
      assert File.exists?(config_file(base_dir, "source-1-config.txt"))
      assert {:ok, %{contents: "--profile\n"}} = YtDlpConfigFile.read_scope(:profile, 1)
    end
  end

  describe "F05: inherited files are active, blank local files are not" do
    test "builder attaches base and profile but not a blank source file", %{base_dir: base_dir} do
      profile = media_profile_fixture(%{output_path_template: "{{ title }}.%(ext)s"})
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = Repo.preload(media_item_fixture(%{source_id: source.id}), source: :media_profile)

      assert :ok = YtDlpConfigFile.save("--base\n")
      assert :ok = YtDlpConfigFile.save_scope(:profile, profile.id, "--profile\n", :missing)
      assert :ok = YtDlpConfigFile.save_scope(:source, source.id, " \n", :missing)

      refute YtDlpConfigFile.present_scope?(:source, source.id)
      assert YtDlpConfigFile.present_scope?(:profile, profile.id)

      assert {:ok, options} = DownloadOptionBuilder.build(media_item)

      base_path = config_file(base_dir, "base-config.txt")
      profile_path = config_file(base_dir, "media-profile-#{profile.id}-config.txt")
      source_path = config_file(base_dir, "source-#{source.id}-config.txt")

      assert {:config_locations, base_path} in options
      assert {:config_locations, profile_path} in options
      refute Enum.any?(options, &match?({:config_locations, ^source_path}, &1))
    end
  end

  describe "F06: byte boundary" do
    test "accepts exactly 64,000 bytes and rejects 64,001, including multibyte text" do
      exact = String.duplicate("é", 32_000)
      assert byte_size(exact) == YtDlpConfigFile.max_bytes()
      assert :ok = YtDlpConfigFile.save_scope(:media_item, 1, exact, :missing)

      oversized = exact <> "x"
      assert byte_size(oversized) == YtDlpConfigFile.max_bytes() + 1
      assert {:error, :too_large} = YtDlpConfigFile.save_scope(:media_item, 1, oversized, :any)
      assert {:ok, %{contents: ^exact}} = YtDlpConfigFile.read_scope(:media_item, 1)
    end
  end

  describe "F07: oversized and unreadable manual files" do
    test "reports oversized contents without loading them and preserves the file", %{base_dir: base_dir} do
      oversized = String.duplicate("a", YtDlpConfigFile.max_bytes() + 1)
      write_config!(base_dir, "source-1-config.txt", oversized)

      assert {:error, :too_large, %{size: size}} = YtDlpConfigFile.read_scope(:source, 1)
      assert size == byte_size(oversized)
      assert YtDlpConfigFile.present_scope?(:source, 1)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == oversized

      assert :ok = YtDlpConfigFile.clear_scope(:source, 1, :any)
      assert {:ok, %{contents: "", present?: false}} = YtDlpConfigFile.read_scope(:source, 1)
    end

    test "a directory at the target path is unreadable and is not overwritten", %{base_dir: base_dir} do
      target = config_file(base_dir, "source-1-config.txt")
      File.mkdir_p!(target)

      assert {:error, :unreadable, ^target} = YtDlpConfigFile.read_scope(:source, 1)
      refute YtDlpConfigFile.present_scope?(:source, 1)
      assert {:error, :unreadable} = YtDlpConfigFile.save_scope(:source, 1, "new\n", :any)
      assert File.dir?(target)
    end
  end

  describe "F08: filesystem failures preserve the previous file" do
    test "mkdir failure keeps the previous file intact", %{base_dir: base_dir} do
      write_config!(base_dir, "source-1-config.txt", "old\n")
      Application.put_env(:pinchflat, :yt_dlp_config_file_fs, FailingFS)
      Application.put_env(:pinchflat, :test_failing_fs_op, :mkdir_p)

      assert {:error, :eacces} = YtDlpConfigFile.save_scope(:source, 1, "new\n", :any)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "old\n"
    end

    test "write failure keeps the previous file intact and cleans the temp file", %{base_dir: base_dir} do
      write_config!(base_dir, "source-1-config.txt", "old\n")
      Application.put_env(:pinchflat, :yt_dlp_config_file_fs, FailingFS)
      Application.put_env(:pinchflat, :test_failing_fs_op, :write)

      assert {:error, :eacces} = YtDlpConfigFile.save_scope(:source, 1, "new\n", :any)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "old\n"
      refute temp_file_left?(base_dir)
    end

    test "rename failure keeps the previous file intact and cleans the temp file", %{base_dir: base_dir} do
      write_config!(base_dir, "source-1-config.txt", "old\n")
      Application.put_env(:pinchflat, :yt_dlp_config_file_fs, FailingFS)
      Application.put_env(:pinchflat, :test_failing_fs_op, :rename)

      assert {:error, :eacces} = YtDlpConfigFile.save_scope(:source, 1, "new\n", :any)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "old\n"
      refute temp_file_left?(base_dir)

      assert {:error, :eacces} = YtDlpConfigFile.clear_scope(:source, 1, :any)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "old\n"
    end
  end

  describe "F09: readers see complete old or complete new contents" do
    test "a reader during rename sees the old file, then the new file", %{base_dir: base_dir} do
      old = String.duplicate("o", 200)
      new = String.duplicate("n", 200)
      write_config!(base_dir, "source-1-config.txt", old)

      Application.put_env(:pinchflat, :yt_dlp_config_file_fs, BlockingRenameFS)
      Application.put_env(:pinchflat, :test_blocking_rename_pid, self())

      assert {:ok, %{version: version}} = YtDlpConfigFile.read_scope(:source, 1)

      writer = Task.async(fn -> YtDlpConfigFile.save_scope(:source, 1, new, version) end)

      assert_receive {:rename_started, writer_pid}, 5_000
      assert {:ok, %{contents: ^old}} = YtDlpConfigFile.read_scope(:source, 1)

      send(writer_pid, :continue_rename)
      assert :ok = Task.await(writer, 5_000)
      assert {:ok, %{contents: ^new}} = YtDlpConfigFile.read_scope(:source, 1)
    end
  end

  describe "F10 and F11: stale saves" do
    test "concurrent editors cannot both save the same version", %{base_dir: base_dir} do
      write_config!(base_dir, "source-1-config.txt", "original\n")
      assert {:ok, %{version: version}} = YtDlpConfigFile.read_scope(:source, 1)
      Application.put_env(:pinchflat, :yt_dlp_config_file_fs, BlockingRenameFS)
      Application.put_env(:pinchflat, :test_blocking_rename_pid, self())

      first = Task.async(fn -> YtDlpConfigFile.save_scope(:source, 1, "editor-a\n", version) end)
      assert_receive {:rename_started, first_pid}, 5_000

      owner = self()

      second =
        Task.async(fn ->
          send(owner, :second_editor_started)
          YtDlpConfigFile.save_scope(:source, 1, "editor-b\n", version)
        end)

      assert_receive :second_editor_started
      refute_receive {:rename_started, _}, 200
      send(first_pid, :continue_rename)

      assert :ok = Task.await(first, 5_000)
      assert {:error, :stale_conflict} = Task.await(second, 5_000)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "editor-a\n"
    end

    test "a second editor with an old version is rejected and the first save survives", %{base_dir: base_dir} do
      assert :ok = YtDlpConfigFile.save_scope(:source, 1, "original\n", :missing)
      assert {:ok, %{version: version}} = YtDlpConfigFile.read_scope(:source, 1)

      assert :ok = YtDlpConfigFile.save_scope(:source, 1, "editor-a\n", version)
      assert {:error, :stale_conflict} = YtDlpConfigFile.save_scope(:source, 1, "editor-b\n", version)
      assert {:error, :stale_conflict} = YtDlpConfigFile.clear_scope(:source, 1, version)

      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "editor-a\n"
    end

    test "an external edit before save is detected as stale", %{base_dir: base_dir} do
      assert :ok = YtDlpConfigFile.save_scope(:source, 1, "app\n", :missing)
      assert {:ok, %{version: version}} = YtDlpConfigFile.read_scope(:source, 1)

      File.write!(config_file(base_dir, "source-1-config.txt"), "external\n")

      assert {:error, :stale_conflict} = YtDlpConfigFile.save_scope(:source, 1, "app-2\n", version)
      assert File.read!(config_file(base_dir, "source-1-config.txt")) == "external\n"
    end
  end

  describe "F12: invalid scopes, IDs, traversal and symlinks" do
    test "rejects invalid scopes and non-positive/non-integer IDs" do
      assert {:error, :invalid_scope} = YtDlpConfigFile.scope_path(:bogus, 1)
      assert {:error, :invalid_scope} = YtDlpConfigFile.read_scope(:base, 1)

      for id <- [0, -1, "1", nil, 1.5, "1/../../etc/passwd"] do
        assert {:error, :invalid_id} = YtDlpConfigFile.scope_path(:source, id)
      end
    end

    test "rejects a symlinked target and does not write through it", %{base_dir: base_dir} do
      real = Path.join(base_dir, "real.txt")
      File.write!(real, "safe\n")
      File.mkdir_p!(config_dir(base_dir))
      :ok = File.ln_s(real, config_file(base_dir, "source-1-config.txt"))

      assert {:error, :unsafe_path} = YtDlpConfigFile.read_scope(:source, 1)
      assert {:error, :unsafe_path} = YtDlpConfigFile.save_scope(:source, 1, "new\n", :any)
      assert File.read!(real) == "safe\n"
    end

    test "rejects a symlinked config root", %{base_dir: base_dir} do
      root = config_dir(base_dir)
      elsewhere = Path.join(base_dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.rm_rf!(root)
      :ok = File.ln_s(elsewhere, root)

      assert {:error, :unsafe_path} = YtDlpConfigFile.scope_path(:source, 1)
    end
  end

  describe "F13: global and plugin editors are untouched" do
    test "scoped saves leave base and plugin config files unchanged", %{base_dir: base_dir} do
      assert :ok = YtDlpConfigFile.save("--base\n")

      plugin_config = Path.join(PluginDirectory.config_directory(), "example.conf")
      File.mkdir_p!(Path.dirname(plugin_config))
      File.write!(plugin_config, "--plugin\n")

      assert :ok = YtDlpConfigFile.save_scope(:profile, 1, "--profile\n", :missing)
      assert :ok = YtDlpConfigFile.clear_scope(:profile, 1, :any)

      assert YtDlpConfigFile.read() == "--base\n"
      assert File.read!(config_file(base_dir, "base-config.txt")) == "--base\n"
      assert File.read!(plugin_config) == "--plugin\n"
    end
  end

  defp temp_file_left?(base_dir) do
    case File.ls(config_dir(base_dir)) do
      {:ok, entries} -> Enum.any?(entries, &String.contains?(&1, ".tmp-"))
      {:error, _} -> false
    end
  end
end
