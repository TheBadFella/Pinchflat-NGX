defmodule Pinchflat.MediaWatch.OriginalArchive do
  @moduledoc """
  Publishes and verifies the saved original of a watched media item.

  The archive is the first completed local artifact, including the sidecars
  present at that time. It lives under `<media_directory>/.pinchflat-originals/`
  in a directory named after the immutable watch ID. A JSON manifest records
  the role, size and SHA-256 of every copied file, and absent optional sidecars.

  Publication is copy-first: files are streamed into a private temporary
  directory on the same filesystem, verified, fsynced, then the directory is
  renamed into place. An existing published archive is never replaced. These
  helpers do not delete or mutate active media; callers own the guarded
  commit. Saved-original deletion runs only after the context records an
  authenticated, version-bound release intent; interrupted cleanup is resumable.
  """

  require Logger

  alias Pinchflat.Media.MediaItem

  @root_name ".pinchflat-originals"
  @manifest_name "manifest.json"
  @manifest_version 1
  @chunk_size 64 * 1024
  @temporary_prefix ".preparing-"

  @doc "Returns the managed archive root under the media directory."
  def root(opts \\ []) do
    media_root = Keyword.get(opts, :media_root, Application.fetch_env!(:pinchflat, :media_directory))
    Path.join(media_root, @root_name)
  end

  @doc "Returns the archive directory for a watch, keyed by its immutable ID."
  def archive_directory(watch_id, opts \\ []) do
    Path.join(root(opts), Integer.to_string(watch_id))
  end

  @doc "Returns the absolute manifest path for a watch."
  def manifest_path(watch_id, opts \\ []) do
    Path.join(archive_directory(watch_id, opts), @manifest_name)
  end

  @doc "Returns the manifest path relative to the media directory, as stored in the DB."
  def relative_manifest_path(watch_id) when is_integer(watch_id) do
    Path.join([@root_name, Integer.to_string(watch_id), @manifest_name])
  end

  @doc """
  Resolves a manifest path stored in the database.

  Returns {:ok, absolute_path} | {:error, :invalid_manifest_path}.
  """
  def resolve_manifest_path(relative_path) when is_binary(relative_path) do
    with :ok <- validate_relative_manifest_path(relative_path) do
      media_root = Application.fetch_env!(:pinchflat, :media_directory)
      {:ok, Path.expand(Path.join(media_root, relative_path))}
    end
  end

  def resolve_manifest_path(_relative_path), do: {:error, :invalid_manifest_path}

  @doc """
  Copies the current first original and sidecars into a private archive and
  publishes it once.

  Returns {:ok, %{manifest: map(), manifest_path: binary(), archive_directory: binary()}}
          | {:error, term()}.
  """
  def publish(%{id: watch_id} = watcher, %MediaItem{} = media_item, opts \\ [])
      when is_integer(watch_id) and watch_id > 0 do
    final_directory = archive_directory(watch_id, opts)
    final_manifest = Path.join(final_directory, @manifest_name)

    with {:ok, entries, absent_roles} <- collect_entries(media_item, opts),
         :ok <- ensure_root(opts) do
      case existing_archive(final_directory, final_manifest, watch_id) do
        {:ok, manifest} ->
          {:ok,
           %{
             manifest: manifest,
             manifest_path: relative_manifest_path(watch_id),
             archive_directory: final_directory,
             already_published: true
           }}

        :not_published ->
          do_publish(watcher, media_item, entries, absent_roles, final_directory, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Describes a published archive without re-hashing its files.

  Use this for display only. Anything that authorizes deletion or replacement
  must use `verify/2` or `verify_relative/2`, which re-hash every file.

  Returns {:ok, %{bytes: non_neg_integer(), files: non_neg_integer(), manifest_path: binary()}}
          | {:error, term()}.
  """
  def summary(%{original_manifest_path: path, id: watch_id}) when is_binary(path) do
    summary_relative(path, watch_id)
  end

  def summary(%{id: watch_id}) do
    summary_relative(relative_manifest_path(watch_id), watch_id)
  end

  def summary(_watch), do: {:error, :invalid_watch}

  defp summary_relative(relative_path, watch_id) do
    with {:ok, absolute_manifest} <- resolve_manifest_path(relative_path),
         :ok <- validate_managed_manifest(absolute_manifest),
         {:ok, contents} <- File.read(absolute_manifest),
         {:ok, manifest} <- decode_manifest(contents),
         :ok <- verify_watch_identity(manifest, watch_id: watch_id) do
      files = manifest["files"] || []
      bytes = Enum.reduce(files, 0, fn file, total -> total + (file["size"] || 0) end)

      {:ok, %{bytes: bytes, files: length(files), manifest_path: relative_path}}
    end
  end

  @doc """
  Verifies every file recorded in a published manifest.

  Returns {:ok, manifest} | {:error, term()}.
  """
  def verify(manifest_path, opts \\ []) when is_binary(manifest_path) do
    with :ok <- validate_managed_manifest(manifest_path),
         {:ok, contents} <- File.read(manifest_path),
         {:ok, manifest} <- decode_manifest(contents),
         :ok <- verify_watch_identity(manifest, opts),
         :ok <- verify_manifest_files(manifest, Path.dirname(manifest_path)) do
      {:ok, manifest}
    end
  end

  @doc """
  Verifies a manifest referenced by its DB-relative path.

  Returns {:ok, manifest} | {:error, term()}.
  """
  def verify_relative(relative_path, opts \\ []) do
    with {:ok, absolute_path} <- resolve_manifest_path(relative_path) do
      verify(absolute_path, opts)
    end
  end

  @doc "Lists role-based archive downloads without exposing host paths."
  def files(watch) do
    with {:ok, manifest, _path} <- read_watch_manifest(watch) do
      {:ok, Enum.map(manifest["files"], &Map.take(&1, ["role", "size"]))}
    end
  end

  @doc "Resolves one manifest role inside this watch's archive; never accepts a filesystem path."
  def file(watch, role) do
    with {:ok, manifest, path} <- read_watch_manifest(watch),
         %{"path" => name, "size" => size} <- Enum.find(manifest["files"], &(&1["role"] == role)),
         :ok <- validate_archive_file_path(name),
         absolute = Path.join(Path.dirname(path), name),
         :ok <- validate_no_symlink_path(absolute),
         {:ok, stat} <- File.lstat(absolute),
         :ok <- validate_regular_file(stat),
         true <- stat.size == size do
      {:ok, absolute}
    else
      _ -> {:error, :archive_file_unavailable}
    end
  end

  @doc "Digest binding destructive confirmation to this exact manifest."
  def manifest_digest(watch) do
    with {:ok, _manifest, path} <- read_watch_manifest(watch),
         {:ok, contents} <- File.read(path) do
      {:ok, :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)}
    end
  end

  defp read_watch_manifest(watch) do
    with {:ok, path} <- resolve_manifest_path(watch.original_manifest_path),
         :ok <- ensure_watch_directory(path, watch.id),
         :ok <- validate_managed_manifest(path),
         {:ok, contents} <- File.read(path),
         {:ok, manifest} <- decode_manifest(contents),
         :ok <- verify_watch_identity(manifest, watch_id: watch.id),
         true <- manifest["media_item_uuid"] == watch.media_item_uuid do
      {:ok, manifest, path}
    else
      false -> {:error, :archive_identity_mismatch}
      error -> error
    end
  end

  @doc "Resumes an approved deletion. The durable released watch is required; missing files are idempotent."
  def delete_released(%{released_at: released, operation_kind: "delete_original"} = watch)
      when not is_nil(released) do
    with :ok <- ensure_no_replacement_intent(watch.id),
         {:ok, path} <- resolve_manifest_path(watch.original_manifest_path),
         :ok <- ensure_watch_directory(path, watch.id),
         :ok <- validate_no_symlink_path(Path.dirname(path)) do
      case File.read(path) do
        {:ok, _contents} ->
          with {:ok, digest} <- manifest_digest(watch),
               true <- digest == watch.release_manifest_sha256,
               {:ok, manifest, ^path} <- read_watch_manifest(watch),
               :ok <- delete_remaining_files(manifest, Path.dirname(path)),
               :ok <- fsync_directory(Path.dirname(path)),
               {:ok, [@manifest_name]} <- File.ls(Path.dirname(path)),
               :ok <- File.rm(path),
               :ok <- fsync_directory(Path.dirname(path)) do
            remove_empty_archive_directory(Path.dirname(path))
          else
            false -> {:error, :archive_changed_since_confirmation}
            {:ok, _entries} -> {:error, :archive_contains_unexpected_files}
            error -> error
          end

        {:error, :enoent} ->
          remove_empty_archive_directory(Path.dirname(path))

        error ->
          error
      end
    end
  end

  def delete_released(_watch), do: {:error, :confirmation_required}

  defp delete_remaining_files(manifest, directory) do
    Enum.reduce_while(manifest["files"], :ok, fn entry, :ok ->
      with :ok <- validate_archive_file_path(entry["path"]),
           path = Path.join(directory, entry["path"]),
           :ok <- validate_no_symlink_path(path),
           {:ok, stat} <- File.lstat(path),
           :ok <- validate_regular_file(stat),
           {:ok, checksum, size} <- hash_file(path),
           true <- checksum == entry["sha256"] and size == entry["size"],
           :ok <- File.rm(path) do
        {:cont, :ok}
      else
        {:error, :enoent} -> {:cont, :ok}
        false -> {:halt, {:error, :manifest_verification_failed}}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_empty_archive_directory(directory) do
    case File.rmdir(directory) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc """
  Lists the active files an archive publication would capture, using exactly
  the same role and file naming as `publish/3`.

  Returns {:ok, %{entries: [%{role: String.t(), source: binary()}], absent_roles: [String.t()]}}
          | {:error, term()}.
  """
  def archive_entries(%MediaItem{} = media_item, opts \\ []) do
    with {:ok, entries, absent_roles} <- collect_entries(media_item, opts) do
      {:ok,
       %{
         entries: Enum.map(entries, &Map.take(&1, [:role, :source, :file])),
         absent_roles: absent_roles
       }}
    end
  end

  @doc "Removes unpublished temporary archive directories for a watch."
  def cleanup_temporary(watch_id, opts \\ []) when is_integer(watch_id) do
    prefix = "#{@temporary_prefix}#{watch_id}-"

    with :ok <- validate_no_symlink_path(root(opts)),
         {:ok, entries} <- File.ls(root(opts)) do
      entries
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.each(fn entry -> File.rm_rf(Path.join(root(opts), entry)) end)

      :ok
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_publish(watcher, media_item, entries, absent_roles, final_directory, opts) do
    temporary_directory = Path.join(root(opts), "#{@temporary_prefix}#{watcher.id}-#{Ecto.UUID.generate()}")

    with :ok <- File.mkdir(temporary_directory),
         {:ok, copied} <- copy_entries(entries, temporary_directory),
         :ok <- verify_copied(copied, temporary_directory),
         manifest = build_manifest(watcher, media_item, copied, absent_roles),
         :ok <- write_manifest(Path.join(temporary_directory, @manifest_name), manifest),
         :ok <- fsync_directory(temporary_directory),
         :ok <- publish_directory(temporary_directory, final_directory),
         :ok <- fsync_directory(root(opts)) do
      {:ok,
       %{
         manifest: manifest,
         manifest_path: relative_manifest_path(watcher.id),
         archive_directory: final_directory,
         already_published: false
       }}
    else
      {:error, reason} ->
        _ = File.rm_rf(temporary_directory)
        {:error, reason}
    end
  end

  defp ensure_root(opts) do
    root = root(opts)

    with :ok <- validate_no_symlink_path(Path.dirname(root)),
         :ok <- reject_symlink(root),
         :ok <- File.mkdir_p(root),
         :ok <- reject_symlink(root),
         :ok <- validate_no_symlink_path(root) do
      :ok
    else
      {:error, reason} -> {:error, {:archive_root_unavailable, reason}}
    end
  end

  defp existing_archive(final_directory, final_manifest, watch_id) do
    cond do
      File.dir?(final_directory) ->
        case verify(final_manifest, watch_id: watch_id) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, reason} -> {:error, {:archive_conflict, reason}}
        end

      File.exists?(final_directory) ->
        {:error, :archive_conflict}

      true ->
        :not_published
    end
  end

  defp collect_entries(%MediaItem{} = media_item, opts) do
    with {:ok, main_path} <- validate_main_media(media_item) do
      optional = optional_entries(media_item)

      candidates = [%{role: "media", source: main_path} | optional]

      entries =
        candidates
        |> Enum.reduce({[], MapSet.new()}, fn candidate, {entries, seen_paths} ->
          expanded = Path.expand(candidate.source)

          if MapSet.member?(seen_paths, expanded) do
            {entries, seen_paths}
          else
            {[Map.put(candidate, :source, expanded) | entries], MapSet.put(seen_paths, expanded)}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      with {:ok, entries, absent_roles} <- validate_entries(entries, opts) do
        {:ok, name_entries(entries), absent_roles}
      end
    end
  end

  defp validate_main_media(%MediaItem{media_filepath: path}) do
    if is_binary(path) and String.trim(path) != "" do
      {:ok, path}
    else
      {:error, :missing_main_media}
    end
  end

  defp optional_entries(%MediaItem{} = media_item) do
    sidecars = [
      {"thumbnail", media_item.thumbnail_filepath},
      {"metadata", media_item.metadata_filepath},
      {"nfo", media_item.nfo_filepath}
    ]

    subtitles =
      (media_item.subtitle_filepaths || [])
      |> Enum.with_index()
      |> Enum.map(fn
        {[language, path], index} when is_binary(path) ->
          %{role: "subtitle-#{safe_language(language, index)}", source: path}

        {_other, _index} ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    sidecars
    |> Enum.map(fn {role, path} -> if is_binary(path) and String.trim(path) != "", do: %{role: role, source: path} end)
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(subtitles)
    |> Kernel.++(internal_metadata_entries(media_item))
  end

  defp internal_metadata_entries(%MediaItem{metadata: %{} = metadata}) do
    [
      %{role: "internal-thumbnail", source: Map.get(metadata, :thumbnail_filepath)},
      %{role: "internal-metadata", source: Map.get(metadata, :metadata_filepath)}
    ]
    |> Enum.filter(&(is_binary(&1.source) and String.trim(&1.source) != ""))
  end

  defp internal_metadata_entries(_media_item), do: []

  defp safe_language(language, index) do
    if is_binary(language) and Regex.match?(~r/^[A-Za-z0-9_-]{1,16}$/, language) do
      language
    else
      "lang-#{index}"
    end
  end

  defp validate_entries(entries, opts) do
    Enum.reduce_while(entries, {:ok, [], []}, fn entry, {:ok, valid, absent} ->
      case safe_source(entry.source, opts) do
        {:ok, _stat} ->
          {:cont, {:ok, [entry | valid], absent}}

        {:error, :missing_optional_source} when entry.role != "media" ->
          {:cont, {:ok, valid, [entry.role | absent]}}

        {:error, :missing_optional_source} ->
          {:halt, {:error, :missing_main_media}}

        {:error, reason} ->
          {:halt, {:error, {reason, entry.role}}}
      end
    end)
    |> case do
      {:ok, valid, absent} -> {:ok, Enum.reverse(valid), Enum.reverse(absent)}
      error -> error
    end
  end

  defp name_entries(entries) do
    {named, _counts} =
      Enum.map_reduce(entries, %{}, fn entry, counts ->
        occurrence = Map.get(counts, entry.role, 0)
        file = unique_filename(entry.role, entry.source, occurrence)
        {Map.put(entry, :file, file), Map.put(counts, entry.role, occurrence + 1)}
      end)

    named
  end

  defp unique_filename(role, source, occurrence) do
    extension =
      source
      |> Path.extname()
      |> then(fn extension ->
        if Regex.match?(~r/^\.[A-Za-z0-9]{1,10}$/, extension), do: extension, else: ""
      end)

    suffix = if occurrence == 0, do: "", else: "-#{occurrence}"
    "#{role}#{suffix}#{extension}"
  end

  defp safe_source(source, opts) do
    with {:ok, root} <- allowed_root(source, opts),
         {:ok, stat} <- File.lstat(source),
         :ok <- validate_regular_file(stat),
         :ok <- validate_no_symlink_path(root),
         :ok <- validate_no_symlink_path(source) do
      {:ok, stat}
    else
      {:error, :enoent} -> {:error, :missing_optional_source}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed_root(source, opts) do
    expanded = Path.expand(source)

    roots =
      [
        Keyword.get(opts, :media_root),
        Application.get_env(:pinchflat, :media_directory),
        Application.get_env(:pinchflat, :extras_directory),
        Application.get_env(:pinchflat, :metadata_directory)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    case Enum.find(roots, &path_under_directory?(expanded, &1)) do
      nil -> {:error, :source_outside_allowed_roots}
      root -> {:ok, root}
    end
  end

  defp validate_regular_file(%{type: :regular}), do: :ok
  defp validate_regular_file(%{type: :symlink}), do: {:error, :source_is_symlink}
  defp validate_regular_file(_stat), do: {:error, :source_is_not_regular}

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :symlink_path_component}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp validate_no_symlink_path(path) do
    [filesystem_root | parts] = path |> Path.expand() |> Path.split()

    parts
    |> Enum.reduce_while(filesystem_root, fn part, parent ->
      current = Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_path_component}}
        {:error, reason} when reason != :enoent -> {:halt, {:error, reason}}
        _ -> {:cont, current}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _path -> :ok
    end
  end

  defp validate_managed_manifest(path) do
    expanded = Path.expand(path)
    managed_root = Path.expand(root())

    with :ok <- reject_symlink(path),
         true <- path_under_directory?(expanded, managed_root),
         [id, @manifest_name] <- Path.relative_to(expanded, managed_root) |> Path.split(),
         {number, ""} when number > 0 <- Integer.parse(id),
         :ok <- validate_no_symlink_path(expanded),
         {:ok, %{type: :regular}} <- File.lstat(expanded) do
      :ok
    else
      false -> {:error, :invalid_manifest_path}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_manifest_path}
    end
  end

  defp copy_entries(entries, temporary_directory) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, copied} ->
      case copy_entry(entry, temporary_directory) do
        {:ok, copied_entry} -> {:cont, {:ok, [copied_entry | copied]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, copied} -> {:ok, Enum.reverse(copied)}
      error -> error
    end
  end

  defp copy_entry(entry, temporary_directory) do
    destination = Path.join(temporary_directory, entry.file)

    with :ok <- validate_no_symlink_path(entry.source),
         {:ok, before_stat} <- File.lstat(entry.source),
         :ok <- validate_regular_file(before_stat),
         {:ok, checksum, size} <- stream_copy(entry.source, destination),
         :ok <- validate_no_symlink_path(entry.source),
         {:ok, after_stat} <- File.lstat(entry.source),
         :ok <- ensure_source_unchanged(before_stat, after_stat),
         :ok <- ensure_source_content(entry.source, checksum, size) do
      {:ok, entry |> Map.put(:sha256, checksum) |> Map.put(:size, size)}
    else
      {:error, reason} ->
        _ = File.rm(destination)
        {:error, {reason, entry.role}}
    end
  end

  defp stream_copy(source, destination) do
    with {:ok, source_device} <- File.open(source, [:read, :binary]),
         {:ok, destination_device} <- File.open(destination, [:write, :binary, :exclusive]) do
      try do
        copy_stream(source_device, destination_device, :crypto.hash_init(:sha256), 0)
      after
        File.close(source_device)
        File.close(destination_device)
      end
    end
  end

  defp copy_stream(source_device, destination_device, context, size) do
    case IO.binread(source_device, @chunk_size) do
      :eof ->
        case :file.sync(destination_device) do
          :ok -> {:ok, Base.encode16(:crypto.hash_final(context), case: :lower), size}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      data ->
        with :ok <- IO.binwrite(destination_device, data) do
          copy_stream(source_device, destination_device, :crypto.hash_update(context, data), size + byte_size(data))
        end
    end
  end

  defp ensure_source_unchanged(%{size: size, mtime: mtime, inode: inode}, %{size: size, mtime: mtime, inode: inode}),
    do: :ok

  defp ensure_source_unchanged(_before, _after), do: {:error, :source_changed_during_archive}

  defp verify_copied(copied, temporary_directory) do
    Enum.reduce_while(copied, :ok, fn entry, :ok ->
      case hash_file(Path.join(temporary_directory, entry.file)) do
        {:ok, checksum, size} when checksum == entry.sha256 and size == entry.size ->
          {:cont, :ok}

        {:ok, _checksum, _size} ->
          {:halt, {:error, {:archive_verification_failed, entry.role}}}

        {:error, reason} ->
          {:halt, {:error, {reason, entry.role}}}
      end
    end)
  end

  defp hash_file(path) do
    with {:ok, device} <- File.open(path, [:read, :binary]) do
      try do
        hash_stream(device, :crypto.hash_init(:sha256), 0)
      after
        File.close(device)
      end
    end
  end

  defp hash_stream(device, context, size) do
    case IO.binread(device, @chunk_size) do
      :eof -> {:ok, Base.encode16(:crypto.hash_final(context), case: :lower), size}
      {:error, reason} -> {:error, reason}
      data -> hash_stream(device, :crypto.hash_update(context, data), size + byte_size(data))
    end
  end

  defp build_manifest(watcher, media_item, copied, absent_roles) do
    %{
      "version" => @manifest_version,
      "watch_id" => watcher.id,
      "media_item_uuid" => media_item.uuid,
      "media_id" => media_item.media_id,
      "published_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "files" =>
        Enum.map(copied, fn entry ->
          %{"role" => entry.role, "path" => entry.file, "size" => entry.size, "sha256" => entry.sha256}
        end),
      "absent_roles" => absent_roles
    }
  end

  defp write_manifest(path, manifest) do
    case File.open(path, [:write, :binary]) do
      {:ok, device} ->
        try do
          with :ok <- IO.binwrite(device, Jason.encode!(manifest)) do
            :file.sync(device)
          end
        after
          File.close(device)
        end

      error ->
        error
    end
  end

  defp publish_directory(temporary_directory, final_directory) do
    # Exclusively reserve the immutable ID before rename. Never replace an
    # existing (even empty) directory from another publisher or failed run.
    with :ok <- validate_no_symlink_path(Path.dirname(final_directory)),
         :ok <- File.mkdir(final_directory),
         :ok <- validate_no_symlink_path(final_directory) do
      case File.rename(temporary_directory, final_directory) do
        :ok -> :ok
        {:error, reason} -> {:error, {:archive_publish_failed, reason}}
      end
    else
      {:error, :eexist} -> {:error, :archive_already_published}
      {:error, reason} -> {:error, {:archive_publish_failed, reason}}
    end
  end

  defp decode_manifest(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"version" => @manifest_version, "files" => files} = manifest} when is_list(files) ->
        {:ok, manifest}

      {:ok, %{"version" => _other}} ->
        {:error, :unsupported_manifest_version}

      {:ok, _other} ->
        {:error, :invalid_manifest}

      {:error, _reason} ->
        {:error, :invalid_manifest}
    end
  end

  defp verify_watch_identity(_manifest, []), do: :ok

  defp verify_watch_identity(manifest, opts) do
    case Keyword.fetch(opts, :watch_id) do
      {:ok, watch_id} ->
        if manifest["watch_id"] == watch_id, do: :ok, else: {:error, :manifest_watch_mismatch}

      :error ->
        :ok
    end
  end

  defp ensure_source_content(source, checksum, size) do
    case hash_file(source) do
      {:ok, ^checksum, ^size} -> :ok
      {:ok, _checksum, _size} -> {:error, :source_changed_during_archive}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_manifest_files(manifest, archive_directory) do
    manifest["files"]
    |> Enum.reduce_while(:ok, fn
      %{"path" => path, "size" => size, "sha256" => checksum, "role" => _role}, :ok
      when is_binary(path) and is_integer(size) and is_binary(checksum) ->
        with :ok <- validate_archive_file_path(path),
             {:ok, stat} <- File.lstat(Path.join(archive_directory, path)),
             :ok <- validate_regular_file(stat),
             true <- stat.size == size,
             {:ok, actual_checksum, _actual_size} <- hash_file(Path.join(archive_directory, path)),
             true <- actual_checksum == checksum do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :manifest_verification_failed}}
          {:error, :enoent} -> {:halt, {:error, :manifest_file_missing}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, :ok ->
        {:halt, {:error, :invalid_manifest}}
    end)
  end

  defp validate_archive_file_path(path) do
    cond do
      Path.type(path) != :relative -> {:error, :invalid_manifest_path}
      ".." in Path.split(path) -> {:error, :invalid_manifest_path}
      Path.basename(path) != path -> {:error, :invalid_manifest_path}
      Path.split(path) == [] -> {:error, :invalid_manifest_path}
      true -> :ok
    end
  end

  defp ensure_no_replacement_intent(watch_id) do
    intent_path = Path.join(archive_directory(watch_id), "replacement_intent.json")

    if File.lstat(intent_path) == {:error, :enoent} do
      :ok
    else
      {:error, :replacement_in_progress}
    end
  end

  defp ensure_watch_directory(absolute_manifest, watch_id) do
    expected = manifest_path(watch_id)

    if Path.expand(absolute_manifest) == Path.expand(expected) do
      :ok
    else
      {:error, :manifest_path_mismatch}
    end
  end

  defp validate_relative_manifest_path(relative_path) do
    parts = Path.split(relative_path)

    cond do
      Path.type(relative_path) != :relative -> {:error, :invalid_manifest_path}
      ".." in parts -> {:error, :invalid_manifest_path}
      List.first(parts) != @root_name -> {:error, :invalid_manifest_path}
      List.last(parts) != @manifest_name -> {:error, :invalid_manifest_path}
      true -> :ok
    end
  end

  defp fsync_directory(path) do
    # The Erlang file driver rejects directory handles with :eisdir on Linux.
    # sync -f calls syncfs for the containing filesystem, including directory
    # metadata. Refuse publication if the command is missing or fails.
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

  defp path_under_directory?(path, directory) do
    expanded_path = Path.expand(path)
    expanded_directory = Path.expand(directory)
    separator = directory_separator(expanded_directory)

    expanded_path == expanded_directory or String.starts_with?(expanded_path, expanded_directory <> separator)
  end

  defp directory_separator(path) do
    if String.contains?(path, "\\"), do: "\\", else: "/"
  end
end
