defmodule Pinchflat.PluginFixtures do
  @moduledoc false

  @default_entries [
    {"yt_dlp_plugins/extractor/sample.py", "class SampleIE:\n  pass\n"}
  ]

  @bgutil_modules ~w(getpot_bgutil.py getpot_bgutil_http.py getpot_bgutil_script.py)

  @doc """
  Returns archive entries with the module layout of the bgutil-ytdlp-pot-provider 2.0.0
  release archive that the Dockerfiles bundle. Only the module names are real.
  """
  def bgutil_plugin_entries do
    Enum.map(@bgutil_modules, &{"yt_dlp_plugins/extractor/#{&1}", "# stub\n"})
  end

  @doc """
  Writes a directory holding a bgutil-shaped zip, the way the Dockerfiles ship the bundled
  plugin, and returns the directory path. The caller removes it.
  """
  def bundled_bgutil_directory_fixture do
    directory =
      Path.join([
        System.tmp_dir!(),
        "bundled-bgutil-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "bgutil-ytdlp-pot-provider.zip"), plugin_zip_fixture(bgutil_plugin_entries()))
    directory
  end

  @doc """
  Builds an in-memory yt-dlp plugin archive.
  """
  def plugin_zip_fixture(entries \\ @default_entries) do
    {:ok, {_name, binary}} =
      entries
      |> Enum.map(fn {name, contents} -> {String.to_charlist(name), contents} end)
      |> then(&:zip.create(~c"plugin.zip", &1, [:memory]))

    binary
  end

  @doc """
  Writes a plugin archive to a unique temporary path and returns the path.
  """
  def plugin_zip_file_fixture(entries \\ @default_entries) do
    path =
      Path.join([
        System.tmp_dir!(),
        "plugin-fixture-#{System.unique_integer([:positive])}.zip"
      ])

    File.write!(path, plugin_zip_fixture(entries))
    path
  end
end
