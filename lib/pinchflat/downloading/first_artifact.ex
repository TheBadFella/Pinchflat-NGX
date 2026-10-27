defmodule Pinchflat.Downloading.FirstArtifact do
  @moduledoc """
  Keeps the first successful transfer recoverable when its initial database
  metadata/marker write fails. This is not a completed watch or an M2 archive.
  """

  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.MetadataFileHelpers

  defp directory(%MediaItem{} = item) do
    Path.join(MetadataFileHelpers.metadata_directory_for(item), "first-artifact-#{item.uuid}")
  end

  @doc "Stores an identity-bound copy and a small durable journal before the first database write."
  def remember(%MediaItem{} = item, parsed_json, staged_path) do
    path = parsed_json["filepath"]
    dir = directory(item)
    copy = Path.join(dir, "media")
    journal = Path.join(dir, "intent.json")

    with :ok <- valid_media_path(staged_path, :staged),
         :ok <- safe_destination(path),
         {:error, :enoent} <- File.lstat(journal),
         :ok <- private_directory(dir),
         :ok <- copy_exclusive(staged_path, copy),
         :ok <- sync_file(copy),
         {:ok, hash} <- hash_file(copy),
         {:ok, ^hash} <- hash_file(staged_path),
         metadata = MetadataFileHelpers.compress_and_store_metadata_for(item, parsed_json),
         :ok <- sync_file(metadata),
         :ok <-
           write_journal(journal, %{uuid: item.uuid, path: path, hash: hash, metadata: metadata, phase: "prepared"}) do
      :ok
    else
      error -> {:error, error}
    end
  end

  @doc "Marks the transfer complete only after every staged path has moved."
  def mark_transferred(%MediaItem{} = item, transferred_json) do
    path = Path.join(directory(item), "intent.json")

    with :ok <- safe_journal_directory(directory(item)),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"uuid" => uuid, "path" => active, "hash" => hash, "metadata" => expected} = entry} <-
           Jason.decode(bytes),
         true <- uuid == item.uuid and transferred_json["filepath"] == active,
         {:ok, ^hash} <- hash_file(active),
         ^expected <- MetadataFileHelpers.compress_and_store_metadata_for(item, transferred_json),
         :ok <- sync_file(expected) do
      write_journal(path, Map.put(entry, "phase", "transferred"))
    else
      _ -> {:error, :first_artifact_transfer_uncertain}
    end
  end

  @doc "Returns whether an interrupted first-artifact journal needs recovery."
  def pending?(%MediaItem{} = item) do
    # An incomplete or swapped intent directory is uncertain, not permission
    # to run yt-dlp a second time over the first artifact.
    File.lstat(directory(item)) != {:error, :enoent}
  end

  @doc "Restores only the same verified first artifact; a changed or missing path must be repaired manually."
  def recover(%MediaItem{} = item) do
    dir = directory(item)
    journal = Path.join(dir, "intent.json")

    with :ok <- safe_journal_directory(dir),
         {:ok, %{type: :regular}} <- File.lstat(journal),
         {:ok, bytes} <- File.read(journal),
         {:ok, %{"uuid" => uuid, "path" => path, "hash" => hash, "metadata" => metadata, "phase" => "transferred"}} <-
           Jason.decode(bytes),
         true <- uuid == item.uuid and metadata == Path.join(Path.dirname(dir), "metadata.json.gz"),
         :ok <- valid_media_path(path),
         {:ok, ^hash} <- hash_file(Path.join(dir, "media")),
         {:ok, ^hash} <- hash_file(path),
         {:ok, parsed_json} <- MetadataFileHelpers.read_compressed_metadata(metadata),
         true <- parsed_json["filepath"] == path do
      {:ok, parsed_json}
    else
      _ -> {:error, :first_artifact_needs_recovery}
    end
  end

  @doc "Reads the immutable first successful postprocessing time bound to this transferred artifact."
  def completed_at(%MediaItem{} = item) do
    with {:ok, entry} <- transferred_entry(item),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(directory(item), "completed.json")),
         {:ok, bytes} <- File.read(Path.join(directory(item), "completed.json")),
         {:ok, %{"uuid" => uuid, "hash" => hash, "path" => path, "at" => value}} <- Jason.decode(bytes),
         true <- uuid == item.uuid and hash == entry["hash"] and path == entry["path"],
         {:ok, time, 0} <- DateTime.from_iso8601(value),
         :ok <- sync_file(directory(item)) do
      time
    else
      _ -> nil
    end
  end

  @doc "Publishes the first completion record exclusively; concurrent successes cannot replace it."
  def mark_completed(%MediaItem{} = item, now) do
    dir = directory(item)
    destination = Path.join(dir, "completed.json")
    temporary = destination <> ".#{Ecto.UUID.generate()}"

    case transferred_entry(item) do
      {:ok, entry} ->
        if completed_at(item) do
          :ok
        else
          try do
            content = %{uuid: item.uuid, hash: entry["hash"], path: entry["path"], at: DateTime.to_iso8601(now)}

            with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]),
                 :ok <- IO.binwrite(file, Jason.encode!(content)),
                 :ok <- :file.sync(file),
                 :ok <- File.close(file),
                 result <- File.ln(temporary, destination),
                 true <- result in [:ok, {:error, :eexist}],
                 :ok <- sync_file(dir),
                 %DateTime{} <- completed_at(item) do
              :ok
            else
              _ -> {:error, :first_artifact_completion_uncertain}
            end
          after
            _ = File.rm(temporary)
          end
        end

      {:error, :invalid_first_artifact_journal} ->
        # Default-off first downloads have no journal. A missing watched
        # journal must never be mistaken for permission to enroll.
        if not pending?(item) and Pinchflat.MediaWatch.effective_watch_window_days(item.source) == 0 do
          :ok
        else
          {:error, :invalid_first_artifact_journal}
        end
    end
  end

  defp transferred_entry(item) do
    dir = directory(item)

    with :ok <- safe_journal_directory(dir),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(dir, "intent.json")),
         {:ok, bytes} <- File.read(Path.join(dir, "intent.json")),
         {:ok, %{"uuid" => uuid, "phase" => "transferred", "hash" => hash, "path" => path} = entry} <-
           Jason.decode(bytes),
         true <- uuid == item.uuid and is_binary(hash) and is_binary(path) do
      {:ok, entry}
    else
      _ -> {:error, :invalid_first_artifact_journal}
    end
  end

  @doc "Removes only the owned recovery copy after the completed item and watch commit."
  def clear(%MediaItem{} = item) do
    dir = directory(item)

    with :ok <- safe_journal_directory(dir) do
      _ = File.rm(Path.join(dir, "intent.json"))
      _ = File.rm(Path.join(dir, "completed.json"))
      _ = File.rm(Path.join(dir, "media"))
      _ = File.rmdir(dir)
      :ok
    end
  end

  defp valid_media_path(path, mode \\ :transferred)

  defp valid_media_path(path, mode) when is_binary(path) do
    root = Application.fetch_env!(:pinchflat, :media_directory) |> Path.expand()
    expanded = Path.expand(path)

    roots =
      if mode == :staged,
        do: [root, DownloadStaging.configured_directory(), DownloadStaging.replacement_directory()],
        else: [root]

    if Path.type(path) == :absolute and
         Enum.any?(roots, fn candidate ->
           is_binary(candidate) and String.starts_with?(expanded, Path.expand(candidate) <> "/") and
             :ok == no_symlink_ancestors(Path.expand(candidate), expanded)
         end) and match?({:ok, %{type: :regular}}, File.lstat(expanded)) do
      :ok
    else
      {:error, :invalid_first_artifact}
    end
  end

  defp valid_media_path(_, _), do: {:error, :invalid_first_artifact}

  defp safe_destination(path) when is_binary(path) do
    root = Application.fetch_env!(:pinchflat, :media_directory) |> Path.expand()
    expanded = Path.expand(path)

    if Path.type(path) == :absolute and String.starts_with?(expanded, root <> "/") and
         :ok == no_symlink_ancestors(root, expanded) and
         File.lstat(expanded) == {:error, :enoent} do
      :ok
    else
      {:error, :first_artifact_destination_exists}
    end
  end

  defp safe_destination(_), do: {:error, :invalid_first_artifact_destination}

  defp safe_journal_directory(dir) do
    root = Application.fetch_env!(:pinchflat, :metadata_directory) |> Path.expand()

    with :ok <- no_symlink_ancestors(root, dir),
         {:ok, %{type: :directory}} <- File.lstat(dir) do
      :ok
    end
  end

  defp private_directory(dir) do
    root = Application.fetch_env!(:pinchflat, :metadata_directory) |> Path.expand()

    with :ok <- no_symlink_ancestors(root, dir),
         :ok <- File.mkdir_p(dir),
         :ok <- no_symlink_ancestors(root, dir) do
      File.chmod(dir, 0o700)
    end
  end

  defp no_symlink_ancestors(root, path) do
    components = Path.relative_to(path, root) |> Path.split()

    [root | Enum.scan(components, root, &Path.join(&2, &1))]
    |> Enum.reduce_while(:ok, fn component, _ ->
      case File.lstat(component) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :first_artifact_symlink}}
        _ -> {:cont, :ok}
      end
    end)
  end

  defp copy_exclusive(source, destination) do
    with {:ok, output} <- File.open(destination, [:write, :exclusive, :binary]) do
      try do
        source |> File.stream!([], 1024 * 1024) |> Enum.each(&IO.binwrite(output, &1))
        :file.sync(output)
      after
        File.close(output)
      end
    end
  end

  defp hash_file(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, stream} <- File.open(path, [:read, :binary]) do
      hash = IO.binstream(stream, 1024 * 1024) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      File.close(stream)
      {:ok, Base.encode16(:crypto.hash_final(hash), case: :lower)}
    end
  end

  defp sync_file(path) do
    case System.cmd("sync", ["-f", path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:error, :first_artifact_sync_failed}
    end
  end

  defp write_journal(path, content) do
    temporary = path <> ".#{Ecto.UUID.generate()}"

    with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]),
         :ok <- IO.binwrite(file, Jason.encode!(content)),
         :ok <- :file.sync(file),
         :ok <- File.close(file),
         :ok <- File.rename(temporary, path),
         :ok <- sync_file(Path.dirname(path)) do
      :ok
    else
      error ->
        _ = File.rm(temporary)
        {:error, error}
    end
  end
end
