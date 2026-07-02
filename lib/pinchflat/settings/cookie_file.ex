defmodule Pinchflat.Settings.CookieFile do
  @moduledoc """
  Manages the user-provided `cookies.txt` file that yt-dlp uses to access
  age-restricted, members-only, or otherwise gated content.

  The file lives in the configured `:extras_directory` and is created (blank)
  on boot by `Pinchflat.Boot.PreJobStartupTasks`. yt-dlp only attaches it when
  it exists and is non-empty (see `Pinchflat.YtDlp.CommandRunner`).
  """

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @filename "cookies.txt"

  @doc """
  Returns the absolute path to the cookies file.
  """
  def filepath do
    base_dir = Application.get_env(:pinchflat, :extras_directory)
    Path.join(base_dir, @filename)
  end

  @doc """
  Returns true if a cookies file exists and has non-whitespace contents.
  """
  def present? do
    FSUtils.exists_and_nonempty?(filepath())
  end

  @doc """
  Reads the raw contents of the cookies file.

  Returns {:ok, binary()} | {:error, File.posix()}
  """
  def read do
    File.read(filepath())
  end

  @doc """
  Replaces the cookies file with the contents at `source_path` (e.g. an uploaded
  temp file). Ensures the destination directory exists.

  Returns :ok | {:error, File.posix()}
  """
  def save_from_path(source_path) do
    dest = filepath()
    File.mkdir_p!(Path.dirname(dest))
    File.cp(source_path, dest)
  end

  @doc """
  Clears the cookies file by writing blank contents (rather than deleting it,
  to keep the boot-time invariant that the file exists).

  Returns :ok | {:error, File.posix()}
  """
  def clear do
    File.write(filepath(), "")
  end

  @doc """
  Validates the cookies file _offline_ by parsing it as a Netscape-format
  cookie jar. This deliberately avoids a live network check (a public video
  succeeds even with bad cookies, while an auth-gated check fails for cookies
  only used to bypass bot-detection), so instead it surfaces the failures that
  are actually common: empty, malformed, or fully-expired files.

  Returns:
    - {:ok, %{total: n, active: n, expired: n}}
    - {:error, :empty}
    - {:error, :invalid}
  """
  def validate(now \\ System.system_time(:second)) do
    case read() do
      {:ok, contents} -> validate_contents(contents, now)
      {:error, _} -> {:error, :empty}
    end
  end

  defp validate_contents(contents, now) do
    if String.trim(contents) == "" do
      {:error, :empty}
    else
      cookies =
        contents
        |> String.split(["\r\n", "\n"])
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)

      case cookies do
        [] ->
          {:error, :invalid}

        cookies ->
          expired = Enum.count(cookies, fn expiry -> expiry != 0 and expiry < now end)

          {:ok, %{total: length(cookies), active: length(cookies) - expired, expired: expired}}
      end
    end
  end

  # Netscape cookie format: domain \t flag \t path \t secure \t expiry \t name \t value
  # Comment lines start with `#` (except the `#HttpOnly_` domain prefix). Returns the
  # cookie's expiry (integer) for valid lines, otherwise nil.
  defp parse_line(line) do
    cond do
      String.trim(line) == "" -> nil
      String.starts_with?(line, "#") and not String.starts_with?(line, "#HttpOnly_") -> nil
      true -> parse_fields(String.split(line, "\t"))
    end
  end

  defp parse_fields(fields) when length(fields) >= 7 do
    expiry = Enum.at(fields, 4)

    case Integer.parse(String.trim(expiry)) do
      {seconds, _} -> seconds
      :error -> nil
    end
  end

  defp parse_fields(_fields), do: nil
end
