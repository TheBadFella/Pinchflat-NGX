defmodule Pinchflat.PluginFixtures do
  @moduledoc false

  @default_entries [
    {"yt_dlp_plugins/extractor/sample.py", "class SampleIE:\n  pass\n"}
  ]

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
