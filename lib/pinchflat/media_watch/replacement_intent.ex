defmodule Pinchflat.MediaWatch.ReplacementIntent do
  @moduledoc """
  Durable per-watch journal for an in-flight active-file replacement.

  The journal is published before the first active file is touched and records
  the operation identity, the lease and observation versions that authorized
  it, the SHA-256 pre-image of every archived active file, and the intended
  destination hashes for the staged replacement. A crashed or abandoned
  replacement can therefore be decided from disk and the database together:

    * the media item's watch row stores the committed operation ID, so recovery
      can tell a committed transfer from an interrupted one;
    * the published original archive is the authoritative pre-image, so an
      interrupted transfer can be rolled back byte-for-byte.

  This journal only exists for watched media. Unwatched downloads keep their
  existing staging behaviour.
  """

  require Logger

  alias Pinchflat.MediaWatch.OriginalArchive

  @version 1
  @file_name "replacement_intent.json"
  @quarantine_prefix "quarantine-"

  @type t :: map()

  @doc "Returns the absolute journal path for a watch."
  def path(watch_id, opts \\ []) when is_integer(watch_id) do
    Path.join(OriginalArchive.archive_directory(watch_id, opts), @file_name)
  end

  @doc "Returns the journal path relative to the media directory."
  def relative_path(watch_id) when is_integer(watch_id) do
    watch_id
    |> OriginalArchive.relative_manifest_path()
    |> Path.dirname()
    |> Path.join(@file_name)
  end

  @doc """
  Publishes a new intent exclusively.

  The record is written to a same-directory temporary file, fsynced, hard
  linked into place, and the directory is fsynced. An existing journal is never
  replaced: a second writer must not be able to claim the same operation.

  Returns {:ok, t()} | {:error, term()}.
  """
  def publish(watch_id, attrs) when is_integer(watch_id) and is_map(attrs) do
    directory = OriginalArchive.archive_directory(watch_id)
    destination = path(watch_id)
    temporary = Path.join(directory, ".#{@file_name}.#{Ecto.UUID.generate()}")

    content =
      attrs
      |> Map.put("version", @version)
      |> Map.put("watch_id", watch_id)

    with :ok <- secure_archive_directory(directory),
         :ok <- write_durable(temporary, content),
         :ok <- link_exclusive(temporary, destination),
         :ok <- sync_directory(directory) do
      {:ok, content}
    else
      error ->
        _ = File.rm(temporary)
        normalize_error(error)
    end
  end

  @doc "Reads the intent for a watch. Returns {:ok, t()} | {:error, term()}."
  def read(watch_id) when is_integer(watch_id) do
    read_path(path(watch_id))
  end

  @doc "Reads an intent by absolute path. Returns {:ok, t()} | {:error, term()}."
  def read_path(path) when is_binary(path) do
    with :ok <- reject_symlink(path),
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, contents} <- File.read(path),
         {:ok, intent} <- decode(contents) do
      {:ok, intent}
    else
      {:error, :enoent} -> {:error, :not_pending}
      {:error, reason} -> normalize_error({:error, reason})
    end
  end

  @doc "Returns true when a journal exists for the watch."
  def pending?(watch_id) when is_integer(watch_id) do
    File.lstat(path(watch_id)) != {:error, :enoent}
  end

  @doc "Returns whether the pending journal belongs to a specific operation."
  def pending_operation?(watch_id, operation_id) when is_integer(watch_id) and is_binary(operation_id) do
    case read(watch_id) do
      {:ok, %{"operation_id" => ^operation_id}} -> true
      _ -> false
    end
  end

  @doc """
  Returns watch IDs whose archive directory holds a pending journal.

  Bounded by the caller's limit. Unreadable or unmanaged entries are skipped
  because they are not proof of an in-flight replacement.
  """
  def pending_watch_ids(limit \\ 25) when is_integer(limit) and limit > 0 do
    case File.ls(OriginalArchive.root()) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while([], fn entry, acc ->
          if length(acc) >= limit do
            {:halt, acc}
          else
            case pending_watch_id(entry) do
              {:ok, watch_id} -> {:cont, [watch_id | acc]}
              :skip -> {:cont, acc}
            end
          end
        end)
        |> Enum.reverse()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Advances an existing intent to a new phase without changing its identity.

  Returns :ok | {:error, term()}.
  """
  def advance(%{"watch_id" => watch_id, "operation_id" => operation_id} = intent, phase)
      when is_binary(operation_id) and is_binary(phase) do
    directory = OriginalArchive.archive_directory(watch_id)
    destination = path(watch_id)
    temporary = Path.join(directory, ".#{@file_name}.#{Ecto.UUID.generate()}")

    with :ok <- reject_symlink(destination),
         {:ok, %{type: :regular}} <- File.lstat(destination),
         :ok <- allow_phase_change(intent["phase"], phase),
         :ok <- write_durable(temporary, Map.put(intent, "phase", phase)),
         :ok <- File.rename(temporary, destination),
         :ok <- sync_directory(directory) do
      :ok
    else
      error ->
        _ = File.rm(temporary)
        normalize_error(error)
    end
  end

  @doc """
  Removes a journal owned by the given operation.

  A mismatched owner is left in place so a stale writer cannot erase the
  evidence of a newer operation.

  Returns :ok | {:error, term()}.
  """
  def clear(watch_id, operation_id) when is_integer(watch_id) do
    path = path(watch_id)

    case read_path(path) do
      {:ok, %{"operation_id" => ^operation_id}} ->
        with :ok <- File.rm(path) do
          sync_directory(OriginalArchive.archive_directory(watch_id))
        end

      {:ok, _other} ->
        {:error, :operation_mismatch}

      {:error, :not_pending} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Restores the active files recorded in an intent, then quarantines any
  destination that did not exist before the replacement.

  The preferred restore is the pre-image backup kept next to each active path:
  it is a rename, so it works even when the failed replacement filled the disk.
  The published archive is the fallback when a backup is missing or damaged.
  Every restored file is re-hashed before the journal is cleared.

  Returns :ok | {:error, term()}.
  """
  def restore(%{"watch_id" => watch_id} = intent) do
    with {:ok, manifest} <- OriginalArchive.verify_relative(manifest_relative_path(watch_id), watch_id: watch_id),
         :ok <- restore_entries(intent, manifest) do
      quarantine_new_destinations(intent)
    end
  end

  def restore(_intent), do: {:error, :invalid_intent}

  @doc "Returns the backup path used to keep an active file's pre-image."
  def backup_path(active_path, operation_id) when is_binary(active_path) and is_binary(operation_id) do
    active_path <> ".pinchflat-previous-" <> operation_id
  end

  @doc """
  Removes pre-image backups after a durable commit. They duplicate the
  published archive, so removing them loses no original bytes.

  Returns :ok.
  """
  def clear_backups(%{"active" => active}) when is_list(active) do
    Enum.each(active, fn entry ->
      backup = entry["backup"]

      if is_binary(backup) and regular_file?(backup) do
        _ = File.rm(backup)
        _ = sync_directory(Path.dirname(backup))
      end
    end)

    :ok
  end

  def clear_backups(_intent), do: :ok

  @doc """
  Moves files that must not stay active into a quarantine directory.

  Returns {:ok, [binary()]} | {:error, term()}.
  """
  def quarantine(watch_id, operation_id, paths) when is_integer(watch_id) and is_binary(operation_id) do
    directory = Path.join(quarantine_root(), "#{@quarantine_prefix}#{watch_id}-#{operation_id}")

    with :ok <- private_directory(directory) do
      moved =
        Enum.reduce_while(paths, [], fn path, acc ->
          case quarantine_one(path, directory) do
            {:ok, moved_path} -> {:cont, [moved_path | acc]}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case moved do
        {:error, reason} -> {:error, reason}
        paths when is_list(paths) -> {:ok, Enum.reverse(paths)}
      end
    end
  end

  @doc "Returns the SHA-256 and byte size of a regular, non-symlinked file."
  def fingerprint(path) when is_binary(path) do
    with {:ok, %{type: :regular} = stat} <- File.lstat(path),
         {:ok, checksum} <- hash_file(path) do
      {:ok, %{sha256: checksum, size: stat.size}}
    else
      {:error, :enoent} -> {:error, :missing_file}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_file}
    end
  end

  @doc "Hashes a regular file's bytes."
  def hash_file(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, stream} <- File.open(path, [:read, :binary]) do
      hash =
        try do
          stream |> IO.binstream(1024 * 1024) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        after
          File.close(stream)
        end

      {:ok, Base.encode16(:crypto.hash_final(hash), case: :lower)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_file}
    end
  end

  @doc "Returns the allowed roots an active file may live under."
  def allowed_roots do
    [:media_directory, :extras_directory, :metadata_directory]
    |> Enum.map(&Application.get_env(:pinchflat, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp restore_entries(intent, manifest) do
    by_role = Map.new(manifest["files"] || [], fn file -> {file["role"], file} end)

    intent
    |> Map.get("active", [])
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case restore_entry(entry, Map.get(by_role, entry["role"]), intent) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {entry["role"], reason}}}
      end
    end)
  end

  defp restore_entry(entry, manifest_entry, intent) do
    path = entry["path"]
    expected = entry["sha256"]
    backup = entry["backup"]

    cond do
      is_binary(backup) and existing_hash(backup) == {:ok, expected} ->
        restore_from_backup(path, backup, expected, intent)

      existing_hash(path) == {:ok, expected} ->
        :ok

      is_map(manifest_entry) and manifest_entry["sha256"] == expected ->
        restore_from_archive(path, manifest_entry, intent["watch_id"])

      true ->
        {:error, :pre_image_unavailable}
    end
  end

  # Renaming the backup back needs no free space, so a replacement that filled
  # the volume can still be undone. Anything already at the active path is a
  # replacement or partial write and is moved to quarantine first.
  defp restore_from_backup(path, backup, expected, intent) do
    with :ok <- safe_active_path(path),
         {:ok, ^expected} <- hash_file(backup),
         :ok <- quarantine_current(path, intent),
         :ok <- File.rename(backup, path),
         {:ok, ^expected} <- hash_file(path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      {:ok, _other} -> {:error, :backup_checksum_mismatch}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp quarantine_current(path, intent) do
    if regular_file?(path) do
      case quarantine(intent["watch_id"], intent["operation_id"], [path]) do
        {:ok, _moved} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp restore_from_archive(path, manifest_entry, watch_id) do
    expected = manifest_entry["sha256"]
    archive_file = manifest_entry["path"]

    with {:ok, absolute_manifest} <- OriginalArchive.resolve_manifest_path(manifest_relative_path(watch_id)),
         archive_source = Path.join(Path.dirname(absolute_manifest), archive_file),
         :ok <- safe_active_path(path),
         {:ok, %{type: :regular, size: size}} <- File.lstat(archive_source),
         true <- size == manifest_entry["size"],
         :ok <- File.mkdir_p(Path.dirname(path)),
         temporary = path <> ".pinchflat-restore-#{Ecto.UUID.generate()}",
         :ok <- copy_exclusive(archive_source, temporary),
         {:ok, ^expected} <- hash_file(temporary),
         :ok <- File.rename(temporary, path),
         {:ok, ^expected} <- hash_file(path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      {:ok, %{type: :symlink}} -> {:error, :active_is_symlink}
      {:error, :enoent} -> {:error, :missing_archive_file}
      {:error, reason} -> {:error, reason}
      false -> {:error, :archive_size_mismatch}
      other -> {:error, other}
    end
  end

  defp existing_hash(path) when is_binary(path), do: hash_file(path)
  defp existing_hash(_path), do: {:error, :not_regular}

  defp regular_file?(path) when is_binary(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))
  defp regular_file?(_path), do: false

  defp quarantine_new_destinations(intent) do
    active_paths =
      intent
      |> Map.get("active", [])
      |> Enum.map(& &1["path"])
      |> MapSet.new()

    new_destinations =
      intent
      |> Map.get("staged", [])
      |> Enum.map(& &1["destination"])
      |> Enum.reject(&MapSet.member?(active_paths, &1))
      |> Enum.filter(&File.exists?/1)

    if new_destinations == [] do
      :ok
    else
      case quarantine(intent["watch_id"], intent["operation_id"], new_destinations) do
        {:ok, _moved} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp quarantine_one(path, directory) when is_binary(path) do
    expanded = Path.expand(path)

    with true <- allowed_path?(expanded),
         :ok <- reject_symlink(expanded) do
      case File.lstat(expanded) do
        {:ok, %{type: :regular}} ->
          name = :crypto.hash(:sha256, expanded) |> Base.encode16(case: :lower)
          destination = Path.join(directory, name)

          if File.lstat(destination) == {:error, :enoent} do
            case File.rename(expanded, destination) do
              :ok ->
                _ = sync_directory(directory)
                {:ok, destination}

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:error, :quarantine_destination_exists}
          end

        {:ok, _other} ->
          {:error, :not_a_regular_file}

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :path_outside_allowed_roots}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quarantine_one(nil, _directory), do: {:ok, nil}

  defp quarantine_root do
    Path.join(Application.fetch_env!(:pinchflat, :media_directory), ".pinchflat-replacements")
  end

  defp private_directory(directory) do
    with :ok <- File.mkdir_p(directory),
         :ok <- reject_symlink(directory) do
      File.chmod(directory, 0o700)
    end
  end

  defp secure_archive_directory(directory) do
    with {:ok, %{type: :directory}} <- File.lstat(directory),
         :ok <- reject_symlink(directory),
         :ok <- no_symlink_ancestors(directory) do
      :ok
    else
      {:error, :enoent} -> {:error, :archive_not_published}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :archive_not_published}
    end
  end

  defp safe_active_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    with true <- Path.type(path) == :absolute,
         true <- allowed_path?(expanded),
         :ok <- no_symlink_ancestors(expanded) do
      :ok
    else
      false -> {:error, :invalid_active_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_active_path(_path), do: {:error, :invalid_active_path}

  defp allowed_path?(expanded) do
    allowed_roots()
    |> Enum.any?(fn root -> expanded == root or String.starts_with?(expanded, root <> "/") end)
  end

  defp no_symlink_ancestors(path) do
    [root | parts] = path |> Path.expand() |> Path.split()

    parts
    |> Enum.reduce_while(root, fn part, parent ->
      current = Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_path_component}}
        _ -> {:cont, current}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _path -> :ok
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :symlink_path_component}
      _ -> :ok
    end
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

  defp write_durable(path, content) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- IO.binwrite(file, Jason.encode!(content)) do
          :file.sync(file)
        end
      after
        File.close(file)
      end
    end
  end

  defp allow_phase_change(phase, phase), do: :ok
  defp allow_phase_change("prepared", "transferring"), do: :ok
  defp allow_phase_change(_, _phase), do: {:error, :invalid_phase}

  defp link_exclusive(temporary, destination) do
    case File.ln(temporary, destination) do
      :ok ->
        _ = File.rm(temporary)
        :ok

      {:error, :eexist} ->
        {:error, :replacement_already_in_progress}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_directory(path) do
    case System.find_executable("sync") do
      nil ->
        {:error, :directory_sync_unavailable}

      executable ->
        case System.cmd(executable, ["-f", path], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:directory_sync_failed, String.trim(output)}}
        end
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{"version" => @version, "watch_id" => watch_id, "operation_id" => operation_id} = intent}
      when is_integer(watch_id) and is_binary(operation_id) ->
        {:ok, intent}

      {:ok, %{"version" => _other}} ->
        {:error, :unsupported_intent_version}

      {:ok, _other} ->
        {:error, :invalid_intent}

      {:error, _reason} ->
        {:error, :invalid_intent}
    end
  end

  defp pending_watch_id(entry) do
    directory = Path.join(OriginalArchive.root(), entry)
    intent_path = Path.join(directory, @file_name)

    case read_path(intent_path) do
      {:ok, %{"watch_id" => watch_id}} -> {:ok, watch_id}
      _ -> :skip
    end
  end

  defp manifest_relative_path(watch_id) do
    watch_id
    |> OriginalArchive.relative_manifest_path()
  end

  defp normalize_error({:error, reason}), do: {:error, reason}
  defp normalize_error(reason) when is_atom(reason), do: {:error, reason}
  defp normalize_error(other), do: {:error, other}
end
