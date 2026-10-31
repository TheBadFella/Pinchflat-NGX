defmodule Pinchflat.YtDlp.PluginDirectory do
  @moduledoc """
  Manages the user-provided yt-dlp plugin packages stored in the extras
  directory.

  Plugins are folders or archives containing a `yt_dlp_plugins` namespace.
  The directory is passed to yt-dlp only when it contains at least one
  loadable entry, preserving the existing command line when unused.
  """

  @directory_name "yt-dlp-plugins"
  @supported_archive_extensions ~w(.zip .whl .egg)
  @max_bytes 25 * 1024 * 1024

  @doc """
  Returns the absolute path to the managed plugin directory.
  """
  def path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), @directory_name)
  end

  @doc """
  Creates the managed plugin directory.

  Returns :ok | {:error, File.posix()}
  """
  def ensure do
    File.mkdir_p(path())
  end

  @doc """
  Returns the maximum accepted plugin archive size in bytes.
  """
  def max_bytes, do: @max_bytes

  @doc """
  Returns the yt-dlp plugin-directory option when a loadable package exists.

  Returns [plugin_dirs: path()] | []
  """
  def options do
    if loadable_entries() == [] do
      []
    else
      [plugin_dirs: path()]
    end
  end

  defp loadable_entries do
    case File.ls(path()) do
      {:ok, entries} -> Enum.filter(entries, &loadable_entry?/1)
      _ -> []
    end
  end

  defp loadable_entry?(name) do
    if hidden?(name) do
      false
    else
      File.dir?(Path.join(path(), name)) or supported_archive?(name)
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".")
  defp supported_archive?(name), do: Path.extname(name) in @supported_archive_extensions
end
