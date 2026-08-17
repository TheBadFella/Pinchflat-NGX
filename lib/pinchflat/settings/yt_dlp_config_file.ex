defmodule Pinchflat.Settings.YtDlpConfigFile do
  @moduledoc """
  Manages the user-provided yt-dlp `base-config.txt` file.

  The file lives in `extras/yt-dlp-configs/` and is created (blank) on boot by
  `Pinchflat.Boot.PreJobStartupTasks`. DownloadOptionBuilder only attaches it
  when it exists and is non-empty.
  """

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @relative_path Path.join("yt-dlp-configs", "base-config.txt")
  @max_bytes 64_000

  @doc """
  Returns the absolute path to the base yt-dlp config file.
  """
  def filepath do
    Path.join(Application.get_env(:pinchflat, :extras_directory), @relative_path)
  end

  @doc """
  Returns true if the config file exists and has non-whitespace contents.
  """
  def present? do
    FSUtils.exists_and_nonempty?(filepath())
  end

  @doc """
  Reads the raw contents of the config file. Missing or unreadable files
  are treated as empty so the editor can always render.

  Returns binary()
  """
  def read do
    case File.read(filepath()) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  @doc """
  Replaces the config file contents. Blank/whitespace-only input clears the
  file (keeping it on disk so boot-time creation stays a no-op).

  Returns :ok | {:error, :too_large} | {:error, File.posix()}
  """
  def save(contents) when is_binary(contents) do
    if byte_size(contents) > @max_bytes do
      {:error, :too_large}
    else
      dest = filepath()
      File.mkdir_p!(Path.dirname(dest))
      File.write(dest, contents)
    end
  end

  @doc """
  Clears the config file by writing blank contents.

  Returns :ok | {:error, File.posix()}
  """
  def clear do
    save("")
  end

  @doc """
  Maximum accepted size of the config file, in bytes.
  """
  def max_bytes, do: @max_bytes
end
