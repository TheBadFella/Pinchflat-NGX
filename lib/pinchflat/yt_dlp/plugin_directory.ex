defmodule Pinchflat.YtDlp.PluginDirectory do
  @moduledoc """
  Manages the user-provided yt-dlp plugin packages stored in the extras
  directory.

  Plugins are folders or archives containing a `yt_dlp_plugins` namespace.
  The directory is passed to yt-dlp only when it contains at least one
  loadable entry, preserving the existing command line when unused.
  """

  alias Pinchflat.HTTP.SafeFetch

  @directory_name "yt-dlp-plugins"
  @config_directory_name "yt-dlp-plugin-configs"
  @config_extension ".conf"
  @metadata_filename ".pinchflat-plugins.json"
  @supported_archive_extensions ~w(.zip .whl .egg)
  @max_bytes 25 * 1024 * 1024
  @max_config_bytes 64 * 1024

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
    with :ok <- File.mkdir_p(path()) do
      File.mkdir_p(config_directory())
    end
  end

  @doc """
  Returns the maximum accepted plugin archive size in bytes.
  """
  def max_bytes, do: @max_bytes

  @doc """
  Returns the maximum accepted plugin config size in bytes.
  """
  def max_config_bytes, do: @max_config_bytes

  @doc """
  Returns the absolute path to the per-plugin config directory.
  """
  def config_directory do
    Path.join(Application.get_env(:pinchflat, :extras_directory), @config_directory_name)
  end

  @doc false
  def temporary_install_path(_filename) do
    Path.join(path(), ".incoming-#{Ecto.UUID.generate()}.tmp")
  end

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

  @doc """
  Installs a plugin archive into the managed directory.

  Options:
    - :filename - destination filename, defaulting to the source basename
    - :source_url - original URL for manual updates
    - :replace - atomically replace an existing archive when true

  Returns {:ok, entry} | {:error, atom()}
  """
  def install_archive(source_path, opts \\ []) do
    filename = Keyword.get(opts, :filename, Path.basename(source_path))
    source_url = normalize_source_url(Keyword.get(opts, :source_url))
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, filename} <- sanitize_filename(filename),
         :ok <- ensure_supported_extension(filename),
         :ok <- validate_size(source_path),
         :ok <- validate_archive(source_path),
         :ok <- validate_destination(filename, replace?) do
      do_install(source_path, filename, source_url)
    end
  end

  @doc """
  Installs a plugin from a direct archive URL.

  Returns {:ok, entry} | {:error, atom() | {:http_status, integer()}}
  """
  def install_from_url(url, opts \\ []) do
    filename = filename_from_url(url)

    with {:ok, filename} <- sanitize_filename(filename),
         :ok <- ensure_supported_extension(filename) do
      download_and_install(url, filename, opts)
    end
  end

  @doc """
  Re-downloads a URL-installed plugin and atomically replaces it.

  Returns {:ok, entry} | {:error, atom() | {:http_status, integer()}}
  """
  def update_from_source(filename, opts \\ []) do
    filename = to_string(filename)

    with {:ok, filename} <- sanitize_filename(filename) do
      do_update_from_source(filename, opts)
    end
  end

  defp do_update_from_source(filename, opts) do
    full_path = Path.join(path(), filename)

    if File.exists?(full_path) do
      case get_in(metadata(), ["plugins", filename, "source_url"]) do
        source_url when is_binary(source_url) and source_url != "" ->
          download_and_install(source_url, filename, Keyword.put(opts, :replace, true))

        _ ->
          {:error, :no_source_url}
      end
    else
      {:error, :not_found}
    end
  end

  defp download_and_install(url, filename, opts) do
    case SafeFetch.fetch(url, safe_fetch_options(opts)) do
      {:ok, body} -> install_downloaded_body(body, filename, url, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_fetch_options(opts) do
    Keyword.take(opts, [:dns_resolver, :max_bytes, :max_redirects, :receive_timeout, :request_timeout])
  end

  defp install_downloaded_body(body, filename, source_url, opts) do
    temporary = temporary_download_path(filename)

    try do
      with :ok <- File.mkdir_p(Path.dirname(temporary)),
           :ok <- File.write(temporary, body) do
        install_archive(temporary,
          filename: filename,
          source_url: source_url,
          replace: Keyword.get(opts, :replace, false)
        )
      else
        {:error, _reason} -> {:error, :file_error}
      end
    after
      _ = File.rm(temporary)
    end
  end

  defp temporary_download_path(filename) do
    directory = Application.get_env(:pinchflat, :tmpfile_directory)
    Path.join(directory, "plugin-download-#{Ecto.UUID.generate()}#{Path.extname(filename)}")
  end

  defp filename_from_url(url) do
    case URI.parse(to_string(url)) do
      %URI{path: path} when is_binary(path) -> path |> Path.basename() |> URI.decode()
      _ -> ""
    end
  end

  @doc """
  Returns the config file path for an installed plugin.

  Returns {:ok, path} | {:error, :invalid_name | :not_found}
  """
  def config_path(filename) do
    with :ok <- validate_config_filename(filename),
         :ok <- validate_plugin_exists(filename) do
      {:ok, config_file_for(filename)}
    end
  end

  @doc """
  Reads a plugin's config file, returning an empty string when none exists.

  Returns {:ok, contents} | {:error, :invalid_name | :not_found | File.posix()}
  """
  def read_config(filename) do
    with :ok <- validate_config_filename(filename),
         :ok <- validate_plugin_exists(filename) do
      case File.read(config_file_for(filename)) do
        {:ok, contents} -> {:ok, contents}
        {:error, :enoent} -> {:ok, ""}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Saves a plugin config file. Blank contents clear the config.

  Returns :ok | {:error, :invalid_name | :not_found | :too_large | File.posix()}
  """
  def save_config(filename, contents) do
    contents = to_string(contents)

    with :ok <- validate_config_filename(filename),
         :ok <- validate_plugin_exists(filename),
         :ok <- validate_config_size(contents) do
      if String.trim(contents) == "" do
        clear_config(filename)
      else
        write_config(filename, contents)
      end
    end
  end

  @doc """
  Clears a plugin's config file.

  Returns :ok | {:error, :invalid_name | :not_found | File.posix()}
  """
  def clear_config(filename) do
    with :ok <- validate_config_filename(filename),
         :ok <- validate_plugin_exists(filename) do
      delete_config_file(filename)
    end
  end

  @doc """
  Returns yt-dlp config-location options for plugins with non-empty configs.

  Returns [config_locations: path]
  """
  def config_locations do
    list()
    |> Enum.filter(& &1.has_config)
    |> Enum.sort_by(& &1.filename)
    |> Enum.map(&{:config_locations, config_file_for(&1.filename)})
  end

  @doc """
  Returns installed plugins sorted by filename.

  Returns [%{name: String.t(), filename: String.t(), kind: :archive | :directory,
  path: String.t(), size: integer() | nil, source_url: String.t() | nil,
  installed_at: String.t() | nil}]
  """
  def list do
    plugins = metadata()["plugins"]

    path()
    |> list_entries()
    |> Enum.map(fn {filename, kind} -> build_entry(filename, kind, Map.get(plugins, filename, %{})) end)
    |> Enum.sort_by(& &1.filename)
  end

  @doc """
  Removes an installed plugin and its metadata.

  Returns :ok | {:error, :invalid_name | :not_found | :file_error}
  """
  def remove(filename) do
    filename = to_string(filename)

    cond do
      filename != Path.basename(filename) -> {:error, :invalid_name}
      hidden?(filename) or filename in ["", ".", ".."] -> {:error, :invalid_name}
      true -> do_remove(filename)
    end
  end

  defp do_install(source_path, filename, source_url) do
    with :ok <- ensure() do
      destination = Path.join(path(), filename)
      temporary = temporary_install_path(filename)

      try do
        with :ok <- copy_file(source_path, temporary),
             :ok <- File.rename(temporary, destination) do
          update_metadata(filename, source_url)
          {:ok, entry_for(filename)}
        else
          {:error, _reason} -> {:error, :file_error}
        end
      after
        _ = File.rm(temporary)
      end
    end
  end

  defp copy_file(source, destination) do
    case File.cp(source, destination) do
      :ok -> :ok
      {:error, _reason} -> {:error, :file_error}
    end
  end

  defp entry_for(filename) do
    kind = if File.dir?(Path.join(path(), filename)), do: :directory, else: :archive
    plugin_metadata = metadata() |> Map.get("plugins", %{}) |> Map.get(filename, %{})

    build_entry(filename, kind, plugin_metadata)
  end

  defp build_entry(filename, :directory, plugin_metadata) do
    plugin_entry(filename, :directory, nil, plugin_metadata)
  end

  defp build_entry(filename, :archive, plugin_metadata) do
    size =
      case File.stat(Path.join(path(), filename)) do
        {:ok, %{size: size}} -> size
        _ -> nil
      end

    plugin_entry(filename, :archive, size, plugin_metadata)
  end

  defp plugin_entry(filename, kind, size, plugin_metadata) do
    %{
      name: if(kind == :archive, do: Path.rootname(filename), else: filename),
      filename: filename,
      kind: kind,
      path: Path.join(path(), filename),
      size: size,
      source_url: plugin_metadata["source_url"],
      installed_at: plugin_metadata["installed_at"],
      has_config: config_present?(filename)
    }
  end

  defp list_entries(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&hidden?/1)
        |> Enum.flat_map(fn filename ->
          full_path = Path.join(directory, filename)

          cond do
            File.dir?(full_path) -> [{filename, :directory}]
            supported_archive?(filename) -> [{filename, :archive}]
            true -> []
          end
        end)

      _ ->
        []
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

  defp do_remove(filename) do
    full_path = Path.join(path(), filename)

    if File.exists?(full_path) do
      case delete_path(full_path) do
        :ok ->
          _ = delete_config_file(filename)
          remove_metadata(filename)
          :ok

        {:error, _reason} ->
          {:error, :file_error}
      end
    else
      {:error, :not_found}
    end
  end

  defp delete_path(full_path) do
    if File.dir?(full_path) do
      case File.rm_rf(full_path) do
        {:ok, _files} -> :ok
        {:error, _reason, _file} -> {:error, :file_error}
      end
    else
      case File.rm(full_path) do
        :ok -> :ok
        {:error, _reason} -> {:error, :file_error}
      end
    end
  end

  defp update_metadata(filename, source_url) do
    plugins =
      metadata()
      |> Map.get("plugins", %{})
      |> prune_missing()
      |> put_source(filename, source_url)

    write_metadata(%{"plugins" => plugins})
  end

  defp remove_metadata(filename) do
    plugins =
      metadata()
      |> Map.get("plugins", %{})
      |> Map.delete(filename)
      |> prune_missing()

    write_metadata(%{"plugins" => plugins})
  end

  defp put_source(plugins, filename, nil), do: Map.delete(plugins, filename)

  defp put_source(plugins, filename, source_url) do
    Map.put(plugins, filename, %{
      "source_url" => source_url,
      "installed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp prune_missing(plugins) do
    plugins
    |> Enum.reject(fn {filename, _metadata} -> not File.exists?(Path.join(path(), filename)) end)
    |> Map.new()
  end

  defp metadata do
    case File.read(metadata_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"plugins" => plugins}} when is_map(plugins) ->
            valid_plugins =
              plugins
              |> Enum.filter(fn {_filename, plugin_metadata} -> is_map(plugin_metadata) end)
              |> Map.new()

            %{"plugins" => valid_plugins}

          _ ->
            empty_metadata()
        end

      _ ->
        empty_metadata()
    end
  end

  defp empty_metadata, do: %{"plugins" => %{}}

  defp write_metadata(metadata) do
    :global.trans({__MODULE__, :metadata}, fn ->
      temporary = Path.join(path(), ".metadata-#{Ecto.UUID.generate()}.tmp")

      result =
        with :ok <- ensure(),
             :ok <- File.write(temporary, Jason.encode!(metadata)) do
          File.rename(temporary, metadata_path())
        end

      _ = File.rm(temporary)
      result
    end)
  end

  defp metadata_path, do: Path.join(path(), @metadata_filename)

  defp validate_archive(source_path) do
    with {:ok, names} <- archive_entry_names(source_path),
         :ok <- validate_safe_entries(names) do
      validate_namespace(names)
    end
  end

  defp archive_entry_names(source_path) do
    case :zip.list_dir(String.to_charlist(source_path)) do
      {:ok, entries} ->
        names =
          Enum.flat_map(entries, fn
            {:zip_file, name, _info, _comment, _offset, _size} -> [normalize_entry_name(to_string(name))]
            _entry -> []
          end)

        {:ok, names}

      {:error, _reason} ->
        {:error, :invalid_archive}
    end
  end

  defp normalize_entry_name(name), do: String.replace_prefix(name, "./", "")

  defp validate_safe_entries(names) do
    if Enum.any?(names, &unsafe_entry?/1), do: {:error, :unsafe_archive}, else: :ok
  end

  defp unsafe_entry?(name) do
    Path.type(name) == :absolute or ".." in Path.split(name)
  end

  defp validate_namespace(names) do
    cond do
      Enum.any?(names, &String.starts_with?(&1, "yt_dlp_plugins/")) -> :ok
      wrapper_directory?(names) -> {:error, :wrapper_directory}
      true -> {:error, :missing_plugin_namespace}
    end
  end

  defp wrapper_directory?(names) do
    names
    |> Enum.map(fn name ->
      case String.split(name, "/", parts: 2) do
        [top, rest] when rest != "" -> top
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [top] -> Enum.any?(names, &String.starts_with?(&1, "#{top}/yt_dlp_plugins/"))
      _ -> false
    end
  end

  defp validate_destination(filename, replace?) do
    destination = Path.join(path(), filename)

    cond do
      File.dir?(destination) -> {:error, :already_installed}
      File.exists?(destination) and not replace? -> {:error, :already_installed}
      true -> :ok
    end
  end

  defp validate_size(source_path) do
    case File.stat(source_path) do
      {:ok, %{size: size}} when size <= @max_bytes -> :ok
      {:ok, _stat} -> {:error, :too_large}
      {:error, _reason} -> {:error, :file_error}
    end
  end

  defp sanitize_filename(filename) do
    filename = to_string(filename)

    cond do
      filename != Path.basename(filename) -> {:error, :invalid_name}
      filename in ["", ".", ".."] -> {:error, :invalid_name}
      hidden?(filename) -> {:error, :invalid_name}
      not String.match?(filename, ~r/\A[A-Za-z0-9][A-Za-z0-9._ -]*\z/) -> {:error, :invalid_name}
      true -> {:ok, filename}
    end
  end

  defp ensure_supported_extension(filename) do
    if supported_archive?(filename), do: :ok, else: {:error, :unsupported_extension}
  end

  defp normalize_source_url(nil), do: nil

  defp normalize_source_url(source_url) do
    case String.trim(source_url) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_config_filename(filename) do
    filename = to_string(filename)

    if filename == Path.basename(filename) and not hidden?(filename) and filename not in ["", ".", ".."] do
      :ok
    else
      {:error, :invalid_name}
    end
  end

  defp validate_plugin_exists(filename) do
    if File.exists?(Path.join(path(), to_string(filename))) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp validate_config_size(contents) do
    if byte_size(contents) <= @max_config_bytes, do: :ok, else: {:error, :too_large}
  end

  defp write_config(filename, contents) do
    with :ok <- File.mkdir_p(config_directory()) do
      destination = config_file_for(filename)
      temporary = Path.join(config_directory(), ".config-#{Ecto.UUID.generate()}.tmp")

      try do
        with :ok <- File.write(temporary, contents),
             :ok <- File.rename(temporary, destination) do
          :ok
        end
      after
        _ = File.rm(temporary)
      end
    end
  end

  defp delete_config_file(filename) do
    case File.rm(config_file_for(filename)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_file_for(filename), do: Path.join(config_directory(), "#{filename}#{@config_extension}")

  defp config_present?(filename) do
    case File.stat(config_file_for(filename)) do
      {:ok, %{size: size}} -> size > 0
      _ -> false
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".")
  defp supported_archive?(name), do: Path.extname(name) in @supported_archive_extensions
end
