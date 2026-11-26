defmodule Pinchflat.Settings.YtDlpConfigFile do
  @moduledoc """
  Manages the user-provided yt-dlp config files.

  The global `base-config.txt` lives in `extras/yt-dlp-configs/` and is created
  (blank) on boot by `Pinchflat.Boot.PreJobStartupTasks`. Scoped files follow the
  existing naming convention:

    * `media-profile-<id>-config.txt`
    * `source-<id>-config.txt`
    * `media-item-<id>-config.txt`

  Scoped reads/writes are path-safe, byte-limited, versioned with SHA-256, and
  serialized per target path. `DownloadOptionBuilder` only attaches files that
  exist and are non-empty.
  """

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @relative_path Path.join("yt-dlp-configs", "base-config.txt")
  @config_directory "yt-dlp-configs"
  @max_bytes 64_000

  @scopes %{
    profile: "media-profile-%{id}-config.txt",
    source: "source-%{id}-config.txt",
    media_item: "media-item-%{id}-config.txt"
  }

  defmodule FS do
    @moduledoc false

    def mkdir_p(path), do: File.mkdir_p(path)
    def write(path, contents, opts), do: File.write(path, contents, opts)
    def rename(source, destination), do: File.rename(source, destination)
    def rm(path), do: File.rm(path)
    def read(path), do: File.read(path)
    def lstat(path), do: File.lstat(path)
    def exists?(path), do: File.exists?(path)
  end

  @doc """
  Returns the absolute path to the global base yt-dlp config file.
  """
  def filepath do
    Path.join(Application.get_env(:pinchflat, :extras_directory), @relative_path)
  end

  @doc """
  Returns the absolute path for a supported scope and positive integer record ID.

  Returns `{:ok, path}` or `{:error, :invalid_scope | :invalid_id | :unsafe_path}`.
  """
  def scope_path(scope, id) do
    with :ok <- validate_scope(scope),
         :ok <- validate_id(id) do
      root = Path.expand(Path.join(extras_directory(), @config_directory))
      path = Path.join(root, filename_for(scope, id))
      expanded = Path.expand(path)

      cond do
        expanded == root or not under_directory?(expanded, root) ->
          {:error, :unsafe_path}

        symlink?(root) or symlink?(expanded) ->
          {:error, :unsafe_path}

        true ->
          {:ok, path}
      end
    end
  end

  @doc """
  Reads a scoped config file.

  Returns:
    * `{:ok, %{contents: binary, version: :missing | binary, present?: boolean, path: binary}}`
    * `{:error, :too_large, %{path: binary, size: integer, version: term}}`
    * `{:error, :unreadable, path}`
    * `{:error, :invalid_scope | :invalid_id | :unsafe_path}`
  """
  def read_scope(scope, id) do
    with {:ok, path} <- scope_path(scope, id) do
      read_path(path)
    end
  end

  @doc """
  Saves a scoped config file with an optional expected version.

  `expected_version` may be `:missing`, a SHA-256 hex string returned by
  `read_scope/2`, or `:any` to force a write. A mismatch returns
  `{:error, :stale_conflict}` and leaves the current file untouched.

  Returns `:ok` or an error.
  """
  def save_scope(scope, id, contents, expected_version \\ :any)

  def save_scope(scope, id, contents, expected_version) when is_binary(contents) do
    if byte_size(contents) > @max_bytes do
      {:error, :too_large}
    else
      with {:ok, path} <- scope_path(scope, id) do
        with_path_lock(path, fn -> do_save(path, contents, expected_version) end)
      end
    end
  end

  def save_scope(_scope, _id, _contents, _expected_version), do: {:error, :invalid_contents}

  @doc """
  Clears a scoped config file by writing blank contents. The file is kept on
  disk, matching the global `clear/0` behavior.

  Returns `:ok` or an error. Accepts the same optional expected version as
  `save_scope/4`.
  """
  def clear_scope(scope, id, expected_version \\ :any) do
    save_scope(scope, id, "", expected_version)
  end

  @doc """
  Removes a scoped config file. Missing files are treated as already removed.
  Used only to clean up an app-created orphan after a rolled-back create.
  """
  def delete_scope(scope, id) do
    with {:ok, path} <- scope_path(scope, id) do
      with_path_lock(path, fn ->
        case fs().rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  @doc """
  Returns true when a scoped file will be attached by `DownloadOptionBuilder`
  (exists and has non-whitespace contents). Oversized non-empty files count as
  present, matching `FilesystemUtils.exists_and_nonempty?/1`.
  """
  def present_scope?(scope, id) do
    case read_scope(scope, id) do
      {:ok, %{present?: present?}} -> present?
      {:error, :too_large, %{size: size}} -> size > 0
      _ -> false
    end
  end

  @doc """
  Returns true if the global config file exists and has non-whitespace contents.
  """
  def present? do
    FSUtils.exists_and_nonempty?(filepath())
  end

  @doc """
  Reads the raw contents of the global config file. Missing or unreadable files
  are treated as empty so the global editor can always render.

  Returns binary()
  """
  def read do
    case File.read(filepath()) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  @doc """
  Replaces the global config file contents. Blank/whitespace-only input clears
  the file (keeping it on disk so boot-time creation stays a no-op).

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
  Clears the global config file by writing blank contents.

  Returns :ok | {:error, File.posix()}
  """
  def clear do
    save("")
  end

  @doc """
  Maximum accepted size of a config file, in bytes.
  """
  def max_bytes, do: @max_bytes

  defp read_path(path) do
    case fs().lstat(path) do
      {:error, :enoent} ->
        {:ok, %{contents: "", version: :missing, present?: false, path: path}}

      {:ok, %{type: :symlink}} ->
        {:error, :unsafe_path}

      {:ok, %{type: :directory}} ->
        {:error, :unreadable, path}

      {:ok, %{size: size} = stat} when size > @max_bytes ->
        {:error, :too_large, %{path: path, size: size, version: {:too_large, size, stat.mtime}}}

      {:ok, _stat} ->
        case fs().read(path) do
          {:ok, contents} ->
            {:ok,
             %{
               contents: contents,
               version: hash(contents),
               present?: String.trim(contents) != "",
               path: path
             }}

          {:error, _reason} ->
            {:error, :unreadable, path}
        end

      {:error, _reason} ->
        {:error, :unreadable, path}
    end
  end

  defp do_save(path, contents, expected_version) do
    case read_path(path) do
      {:ok, current} ->
        if version_matches?(current.version, expected_version) do
          atomic_write(path, contents)
        else
          {:error, :stale_conflict}
        end

      {:error, :too_large, %{version: version}} ->
        if expected_version == :any or expected_version == version do
          atomic_write(path, contents)
        else
          {:error, :too_large}
        end

      {:error, reason, _detail} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp version_matches?(_current, :any), do: true
  defp version_matches?(:missing, :missing), do: true
  defp version_matches?(current, expected) when is_binary(current) and is_binary(expected), do: current == expected
  defp version_matches?(_current, _expected), do: false

  defp atomic_write(path, contents) do
    directory = Path.dirname(path)
    temporary = Path.join(directory, ".#{Path.basename(path)}.tmp-#{unique_suffix()}")

    with :ok <- fs().mkdir_p(directory),
         :ok <- fs().write(temporary, contents, [:binary]) do
      case fs().rename(temporary, path) do
        :ok ->
          :ok

        {:error, reason} when reason in [:eexist, :eacces, :eperm] ->
          case replace_existing(temporary, path) do
            :ok ->
              :ok

            {:error, _replace_reason} = error ->
              _ = fs().rm(temporary)
              error
          end

        {:error, reason} ->
          _ = fs().rm(temporary)
          {:error, reason}
      end
    else
      {:error, reason} ->
        _ = fs().rm(temporary)
        {:error, reason}
    end
  end

  defp replace_existing(temporary, path) do
    backup = path <> ".bak-#{unique_suffix()}"

    case fs().rename(path, backup) do
      :ok ->
        case fs().rename(temporary, path) do
          :ok ->
            _ = fs().rm(backup)
            :ok

          {:error, reason} ->
            _ = fs().rename(backup, path)
            {:error, reason}
        end

      {:error, :enoent} ->
        fs().rename(temporary, path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_path_lock(path, fun) do
    case :global.trans({{__MODULE__, path}, self()}, fun) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  defp validate_scope(scope) when is_atom(scope) and is_map_key(@scopes, scope), do: :ok
  defp validate_scope(_scope), do: {:error, :invalid_scope}

  defp validate_id(id) when is_integer(id) and id > 0, do: :ok
  defp validate_id(_id), do: {:error, :invalid_id}

  defp filename_for(scope, id) do
    @scopes
    |> Map.fetch!(scope)
    |> String.replace("%{id}", Integer.to_string(id))
  end

  defp extras_directory, do: Application.get_env(:pinchflat, :extras_directory)

  defp under_directory?(path, directory) do
    String.starts_with?(path, directory <> directory_separator(directory))
  end

  defp directory_separator(path) do
    if String.contains?(path, "\\"), do: "\\", else: "/"
  end

  defp symlink?(path) do
    case fs().lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  defp fs do
    Application.get_env(:pinchflat, :yt_dlp_config_file_fs, __MODULE__.FS)
  end

  defp hash(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp unique_suffix do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
  end
end
