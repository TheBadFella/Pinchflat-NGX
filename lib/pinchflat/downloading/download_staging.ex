defmodule Pinchflat.Downloading.DownloadStaging do
  @moduledoc """
  Provides optional local staging for yt-dlp download artifacts.

  A staging directory is created per download. Artifacts are kept there until
  yt-dlp has completed, then moved or copied into the configured media root.
  The database only receives paths after that transfer succeeds.
  """

  require Logger

  alias Pinchflat.Diagnostics.DiskSpaceChecker

  @directory_prefix "media-"
  @stale_after_seconds 24 * 60 * 60
  @minimum_free_bytes 1

  @doc """
  Returns the configured staging root, or nil when staging is disabled.

  Returns binary() | nil.
  """
  def configured_directory do
    case Application.get_env(:pinchflat, :download_staging_directory) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Validates the configured staging root without creating a download directory.

  Returns :disabled | {:ok, binary()} | {:error, atom()}.
  """
  def validate_configuration do
    case configured_directory() do
      nil ->
        :disabled

      root ->
        case validate_root(root) do
          {:ok, validated_root} -> {:ok, validated_root}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Creates a unique staging directory for a media item.

  Returns {:ok, binary() | nil} | {:error, atom()}.
  """
  def prepare(media_item_id) do
    case validate_configuration() do
      :disabled ->
        {:ok, nil}

      {:ok, root} ->
        with :ok <- validate_media_item_id(media_item_id),
             :ok <- check_disk_space(root),
             directory = Path.join(root, "#{@directory_prefix}#{media_item_id}-#{Ecto.UUID.generate()}"),
             :ok <- File.mkdir_p(directory) do
          {:ok, directory}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves a relative yt-dlp output path under a staging directory.

  Returns {:ok, binary()} | {:error, :path_escape}.
  """
  def output_path(staging_directory, relative_path)
      when is_binary(staging_directory) and is_binary(relative_path) do
    root = Path.expand(staging_directory)
    path = Path.expand(Path.join(staging_directory, relative_path))

    if Path.type(relative_path) == :relative and path_under_directory?(path, root) and path != root do
      {:ok, path}
    else
      {:error, :path_escape}
    end
  end

  @doc """
  Transfers all files referenced by a successful yt-dlp response into the
  configured media directory and rewrites the response with final paths.

  Missing optional sidecars are nulled so the database cannot retain a path
  into the temporary directory. The main media file is required.

  Returns {:ok, map()} | {:error, atom()}.
  """
  def transfer(parsed_json, staging_directory, opts \\ [])

  def transfer(parsed_json, nil, _opts) when is_map(parsed_json), do: {:ok, parsed_json}

  def transfer(parsed_json, staging_directory, opts) when is_map(parsed_json) and is_binary(staging_directory) do
    with :ok <- validate_staging_directory(staging_directory),
         {:ok, paths} <- artifact_paths(parsed_json),
         {:ok, path_map} <- transfer_paths(paths, staging_directory, opts) do
      {:ok, rewrite_paths(parsed_json, path_map)}
    end
  end

  @doc """
  Removes one download's staging directory. Invalid paths are ignored rather
  than recursively deleting outside the configured root.

  Returns :ok.
  """
  def cleanup(nil), do: :ok

  def cleanup(staging_directory) when is_binary(staging_directory) do
    case configured_directory() do
      nil ->
        :ok

      root ->
        expanded_root = Path.expand(root)
        expanded_directory = Path.expand(staging_directory)

        if expanded_directory != expanded_root and path_under_directory?(expanded_directory, expanded_root) do
          _ = File.rm_rf(expanded_directory)
        else
          Logger.warning("Refusing to clean invalid download staging path")
        end

        :ok
    end
  end

  @doc """
  Removes old, unowned per-item staging directories.

  Active media item IDs are preserved. The default age threshold is one day;
  tests and maintenance callers may provide `stale_after_seconds`.

  Returns :ok.
  """
  def cleanup_stale(active_media_item_ids \\ MapSet.new(), opts \\ []) do
    case validate_configuration() do
      :disabled ->
        :ok

      {:error, reason} ->
        Logger.warning("Download staging cleanup skipped: #{inspect(reason)}")
        :ok

      {:ok, root} ->
        active_ids = MapSet.new(active_media_item_ids)
        stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @stale_after_seconds)

        case File.ls(root) do
          {:ok, entries} ->
            Enum.each(entries, fn entry ->
              directory = Path.join(root, entry)

              if stale_directory?(directory, entry, active_ids, stale_after_seconds) do
                cleanup(directory)
              end
            end)

          {:error, reason} ->
            Logger.warning("Download staging cleanup could not list root: #{inspect(reason)}")
        end

        :ok
    end
  end

  defp validate_root(root) do
    if Path.type(root) != :absolute do
      {:error, :staging_root_must_be_absolute}
    else
      validate_absolute_root(root)
    end
  end

  defp validate_absolute_root(root) do
    expanded_root = Path.expand(root)
    media_root = Application.get_env(:pinchflat, :media_directory) |> Path.expand()

    cond do
      expanded_root == media_root ->
        {:error, :staging_root_matches_media_root}

      not ensure_directory(expanded_root) ->
        {:error, :staging_root_unavailable}

      not writable_directory?(expanded_root) ->
        {:error, :staging_root_not_writable}

      true ->
        {:ok, expanded_root}
    end
  end

  defp ensure_directory(directory) do
    with :ok <- File.mkdir_p(directory),
         {:ok, %{type: :directory}} <- File.stat(directory) do
      true
    else
      _ -> false
    end
  end

  defp writable_directory?(directory) do
    probe = Path.join(directory, ".pinchyt-write-test-#{Ecto.UUID.generate()}")

    case File.write(probe, "") do
      :ok ->
        _ = File.rm(probe)
        true

      {:error, _reason} ->
        false
    end
  end

  defp validate_media_item_id(media_item_id) when is_integer(media_item_id) and media_item_id > 0, do: :ok
  defp validate_media_item_id(_media_item_id), do: {:error, :invalid_media_item_id}

  defp check_disk_space(root) do
    checker = Application.get_env(:pinchflat, :disk_space_checker, DiskSpaceChecker)

    case checker.available_bytes(root) do
      {:ok, available_bytes} when available_bytes >= @minimum_free_bytes ->
        :ok

      {:ok, _available_bytes} ->
        {:error, :insufficient_staging_space}

      :error ->
        # A missing df utility should not make the optional feature unusable.
        :ok
    end
  end

  defp validate_staging_directory(staging_directory) do
    case configured_directory() do
      nil ->
        {:error, :staging_disabled}

      root ->
        expanded_root = Path.expand(root)
        expanded_directory = Path.expand(staging_directory)

        cond do
          expanded_directory == expanded_root -> {:error, :invalid_staging_directory}
          not path_under_directory?(expanded_directory, expanded_root) -> {:error, :invalid_staging_directory}
          not File.dir?(expanded_directory) -> {:error, :invalid_staging_directory}
          true -> :ok
        end
    end
  end

  defp artifact_paths(parsed_json) do
    case parsed_json["filepath"] do
      filepath when is_binary(filepath) ->
        sidecars =
          [parsed_json["infojson_filename"]] ++
            Enum.map(parsed_json["thumbnails"] || [], &Map.get(&1, "filepath")) ++
            Enum.map(Map.values(parsed_json["requested_subtitles"] || %{}), &Map.get(&1, "filepath"))

        optional_paths =
          sidecars
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.map(&{&1, false})

        {:ok, [{filepath, true} | optional_paths]}

      _ ->
        {:error, :missing_media_filepath}
    end
  end

  defp transfer_paths(paths, staging_directory, opts) do
    Enum.reduce_while(paths, {:ok, %{}, []}, fn {source, required?}, {:ok, path_map, transferred} ->
      case transfer_path(source, required?, staging_directory, opts) do
        {:ok, destination, existed?} ->
          {:cont, {:ok, Map.put(path_map, source, destination), [{destination, existed?} | transferred]}}

        {:missing_optional, _destination} ->
          {:cont, {:ok, Map.put(path_map, source, nil), transferred}}

        {:error, reason} ->
          rollback_transfers(transferred)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, path_map, _transferred} -> {:ok, path_map}
      error -> error
    end
  end

  defp transfer_path(source, required?, staging_directory, opts) do
    with {:ok, destination} <- destination_for(source, staging_directory),
         {:ok, source_stat} <- File.stat(source) do
      if source_stat.type == :regular do
        destination_existed? = File.exists?(destination)

        case move_file(source, destination, opts) do
          :ok -> {:ok, destination, destination_existed?}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :invalid_media_artifact}
      end
    else
      {:error, :enoent} ->
        if required? do
          {:error, :missing_media_artifact}
        else
          case destination_for(source, staging_directory) do
            {:ok, destination} -> {:missing_optional, destination}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp destination_for(source, staging_directory) do
    expanded_source = Path.expand(source)
    expanded_staging_directory = Path.expand(staging_directory)

    cond do
      not path_under_directory?(expanded_source, expanded_staging_directory) ->
        {:error, :path_escape}

      expanded_source == expanded_staging_directory ->
        {:error, :invalid_media_artifact}

      true ->
        relative_path = Path.relative_to(expanded_source, expanded_staging_directory)
        media_root = Application.get_env(:pinchflat, :media_directory) |> Path.expand()
        {:ok, Path.expand(Path.join(media_root, relative_path))}
    end
  end

  defp move_file(source, destination, opts) do
    :ok = File.mkdir_p(Path.dirname(destination))

    if Keyword.get(opts, :transfer_mode) == :copy do
      copy_then_rename(source, destination)
    else
      case File.rename(source, destination) do
        :ok ->
          :ok

        {:error, :exdev} ->
          copy_then_rename(source, destination)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp copy_then_rename(source, destination) do
    temporary_destination = destination <> ".pinchyt-copy-#{Ecto.UUID.generate()}"

    case File.cp(source, temporary_destination) do
      :ok ->
        case File.rename(temporary_destination, destination) do
          :ok ->
            File.rm(source)

          {:error, reason} ->
            _ = File.rm(temporary_destination)
            {:error, reason}
        end

      {:error, reason} ->
        _ = File.rm(temporary_destination)
        {:error, reason}
    end
  end

  defp rollback_transfers(transferred) do
    Enum.each(transferred, fn {destination, existed?} ->
      unless existed?, do: File.rm(destination)
    end)
  end

  defp rewrite_paths(parsed_json, path_map) do
    parsed_json
    |> Map.update("filepath", nil, &Map.get(path_map, &1, &1))
    |> Map.update("infojson_filename", nil, &rewrite_optional_path(&1, path_map))
    |> Map.update("thumbnails", [], fn thumbnails ->
      Enum.map(
        thumbnails,
        &Map.update(&1, "filepath", nil, fn filepath -> rewrite_optional_path(filepath, path_map) end)
      )
    end)
    |> Map.update("requested_subtitles", %{}, fn requested_subtitles ->
      Map.new(requested_subtitles, fn {language, attrs} ->
        {language, Map.update(attrs, "filepath", nil, fn filepath -> rewrite_optional_path(filepath, path_map) end)}
      end)
    end)
  end

  defp rewrite_optional_path(nil, _path_map), do: nil
  defp rewrite_optional_path(filepath, path_map), do: Map.get(path_map, filepath, filepath)

  defp stale_directory?(directory, entry, active_ids, stale_after_seconds) do
    with true <- String.starts_with?(entry, @directory_prefix),
         {:ok, media_item_id} <- media_item_id_from_entry(entry),
         false <- MapSet.member?(active_ids, media_item_id),
         {:ok, %{type: :directory, mtime: mtime}} <- File.stat(directory, time: :posix) do
      System.system_time(:second) - mtime >= stale_after_seconds
    else
      _ -> false
    end
  end

  defp media_item_id_from_entry(entry) do
    case Regex.run(~r/^media-(\d+)-/, entry, capture: :all_but_first) do
      [id] -> {:ok, String.to_integer(id)}
      _ -> {:error, :not_a_staging_directory}
    end
  end

  defp path_under_directory?(path, directory) do
    expanded_path = Path.expand(path)
    expanded_directory = Path.expand(directory)

    expanded_path == expanded_directory ||
      String.starts_with?(expanded_path, expanded_directory <> directory_separator(expanded_directory))
  end

  defp directory_separator(path) do
    if String.contains?(path, "\\"), do: "\\", else: "/"
  end
end
