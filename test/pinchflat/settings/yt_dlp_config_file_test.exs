defmodule Pinchflat.Settings.YtDlpConfigFileTest do
  use ExUnit.Case, async: false

  alias Pinchflat.Settings.YtDlpConfigFile

  setup do
    base_dir =
      Path.join([System.tmp_dir!(), "yt_dlp_config_test", Integer.to_string(:erlang.unique_integer([:positive]))])

    File.mkdir_p!(base_dir)
    original = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir}
  end

  describe "filepath/0" do
    test "points at yt-dlp-configs/base-config.txt in the extras directory", %{base_dir: base_dir} do
      assert YtDlpConfigFile.filepath() == Path.join([base_dir, "yt-dlp-configs", "base-config.txt"])
    end
  end

  describe "read/0, save/1, present?/0, and clear/0" do
    test "read returns an empty string when the file is missing" do
      assert YtDlpConfigFile.read() == ""
      refute YtDlpConfigFile.present?()
    end

    test "save writes contents and present? becomes true" do
      assert :ok = YtDlpConfigFile.save("--force-ipv4\n")
      assert YtDlpConfigFile.read() == "--force-ipv4\n"
      assert YtDlpConfigFile.present?()
    end

    test "clear blanks the file but keeps it on disk" do
      assert :ok = YtDlpConfigFile.save("--retries 20\n")
      assert :ok = YtDlpConfigFile.clear()
      refute YtDlpConfigFile.present?()
      assert File.exists?(YtDlpConfigFile.filepath())
    end

    test "rejects oversized contents" do
      oversized = String.duplicate("a", YtDlpConfigFile.max_bytes() + 1)

      assert {:error, :too_large} = YtDlpConfigFile.save(oversized)
    end
  end
end
