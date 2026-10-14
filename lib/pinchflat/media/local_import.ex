defmodule Pinchflat.Media.LocalImport do
  @moduledoc """
  Imports existing media from yt-dlp info sidecars after an explicit preview.
  Files are never moved, rewritten or downloaded. The target source must be paused.
  """

  import Ecto.Query

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @extensions ~w(.mp4 .mkv .webm .m4a .mp3 .opus .ogg .flac .wav .aac .mov .avi .m4v)
  @max_files 5_000
  @max_metadata_size 5_000_000

  @doc """
  Scans a directory relative to the configured downloads mount without changing data.
  Returns {:ok, %{entries: list(), fingerprint: binary(), directory: binary()}} or {:error, reason}.
  """
  def preview(source_id, directory) when is_binary(directory) do
    with %Source{} = source <- Repo.get(Source, source_id),
         :ok <- quiet_source(source),
         {:ok, root} <- directory_path(directory),
         {:ok, files} <- walk([root], []) do
      entries =
        files
        |> Enum.filter(&String.ends_with?(&1, ".info.json"))
        |> Enum.sort()
        |> Enum.map(&entry(source, &1))
        |> reject_duplicate_ids()

      fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary({source, directory, entries})) |> Base.encode16()
      {:ok, %{entries: entries, fingerprint: fingerprint, directory: directory}}
    else
      nil -> {:error, :source_not_found}
      error -> error
    end
  end

  @doc """
  Rescans and applies an unchanged preview in a database transaction. No jobs are enqueued.
  Returns {:ok, %{imported: integer()}} or {:error, reason}.
  """
  def apply_preview(source_id, directory, fingerprint) do
    Repo.transaction(fn ->
      # A write lock prevents indexing/download workers from updating these rows
      # between the fresh preview and import (SQLite has no SELECT FOR UPDATE).
      {locked, _} =
        Repo.update_all(from(s in Source, where: s.id == ^source_id and s.enabled == false), set: [enabled: false])

      if locked != 1, do: Repo.rollback(:pause_source_first)

      case preview(source_id, directory) do
        {:ok, %{fingerprint: ^fingerprint, entries: entries}} ->
          Enum.reduce(entries, %{imported: 0}, fn
            %{status: :ready} = item, result ->
              import_entry(item)
              %{result | imported: result.imported + 1}

            _item, result ->
              result
          end)

        {:ok, _preview} ->
          Repo.rollback(:stale_preview)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp quiet_source(%Source{enabled: true}), do: {:error, :pause_source_first}

  defp quiet_source(source) do
    active =
      from(t in Task,
        join: j in Oban.Job,
        on: j.id == t.job_id,
        left_join: mi in MediaItem,
        on: mi.id == t.media_item_id,
        where: j.state == "executing" and (t.source_id == ^source.id or mi.source_id == ^source.id)
      )

    if Repo.exists?(active), do: {:error, :source_jobs_running}, else: :ok
  end

  defp directory_path(directory) do
    mount = Application.fetch_env!(:pinchflat, :media_directory) |> Path.expand()
    path = Path.expand(directory, mount)

    if path == mount or String.starts_with?(path, mount <> "/") do
      parts = Path.split(Path.relative_to(path, mount))
      with :ok <- real_directory(mount), do: descend(mount, parts)
    else
      {:error, :outside_downloads}
    end
  end

  defp descend(path, []), do: {:ok, path}
  defp descend(path, ["." | parts]), do: descend(path, parts)

  defp descend(path, [part | parts]) do
    next = Path.join(path, part)
    with :ok <- real_directory(next), do: descend(next, parts)
  end

  defp real_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _ -> {:error, :directory_unavailable}
    end
  end

  defp walk([], files), do: {:ok, files}
  defp walk(_pending, files) when length(files) >= @max_files, do: {:error, :too_many_files}

  defp walk([path | pending], files) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with {:ok, names} <- File.ls(path) do
          if length(names) + length(pending) + length(files) > @max_files do
            {:error, :too_many_files}
          else
            walk(Enum.map(names, &Path.join(path, &1)) ++ pending, files)
          end
        end

      {:ok, %{type: :regular}} ->
        walk(pending, [path | files])

      {:ok, %{type: :symlink}} ->
        walk(pending, files)

      _ ->
        {:error, :file_unavailable}
    end
  end

  defp reject_duplicate_ids(entries) do
    counts = entries |> Enum.filter(&(&1.status == :ready)) |> Enum.frequencies_by(& &1.attrs.media_id)

    Enum.map(entries, fn
      %{status: :ready, attrs: %{media_id: id}} = item ->
        if counts[id] > 1, do: %{item | status: :duplicate_media_id}, else: item

      item ->
        item
    end)
  end

  defp entry(source, info_path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_metadata_size <- File.lstat(info_path),
         {:ok, contents} <- File.read(info_path),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(contents),
         {:ok, attrs} <- media_attrs(metadata),
         existing = Repo.get_by(MediaItem, source_id: source.id, media_id: attrs.media_id),
         true <- belongs_to_source?(source, metadata, existing),
         {:ok, media_path, stat} <- media_file(info_path),
         :ok <- unclaimed_file(media_path, existing) do
      attrs =
        Map.merge(attrs, %{
          source_id: source.id,
          media_filepath: media_path,
          predicted_media_filepath: media_path,
          media_size_bytes: stat.size,
          metadata_filepath: info_path,
          prevent_culling: true
        })

      status =
        if existing && (existing.media_filepath || existing.media_downloaded_at), do: :already_recorded, else: :ready

      %{
        status: status,
        info_path: info_path,
        attrs: attrs,
        existing_id: existing && existing.id,
        metadata_hash: :crypto.hash(:sha256, contents),
        file_identity: {stat.size, stat.mtime, stat.inode}
      }
    else
      false -> %{status: :source_mismatch, info_path: info_path}
      {:error, reason} when is_atom(reason) -> %{status: reason, info_path: info_path}
      _ -> %{status: :invalid_metadata, info_path: info_path}
    end
  end

  defp belongs_to_source?(_source, _metadata, %MediaItem{}), do: true

  defp belongs_to_source?(%Source{collection_type: :channel, collection_id: id}, metadata, _),
    do: metadata["channel_id"] == id

  defp belongs_to_source?(%Source{collection_type: :playlist, collection_id: id}, metadata, _),
    do: metadata["playlist_id"] == id

  defp belongs_to_source?(%Source{collection_type: :video, collection_id: id}, metadata, _), do: metadata["id"] == id

  defp media_attrs(%{"id" => id, "title" => title, "upload_date" => date} = metadata)
       when is_binary(id) and is_binary(title) and is_binary(date) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id) and String.trim(title) != "" and Regex.match?(~r/\A\d{8}\z/, date) do
      parse_media_attrs(metadata)
    else
      {:error, :invalid_metadata}
    end
  end

  defp media_attrs(_metadata), do: {:error, :invalid_metadata}

  defp parse_media_attrs(metadata) do
    # Use the same indexing conversion; invalid sidecar fields are reported rather
    # than allowed to abort the scan of otherwise importable files.
    metadata = Map.put(metadata, "original_url", "https://www.youtube.com/watch?v=#{metadata["id"]}")
    attrs = metadata |> YtDlpMedia.response_to_struct() |> Map.from_struct()
    {:ok, attrs}
  rescue
    _error in [ArgumentError, MatchError, RuntimeError, FunctionClauseError] -> {:error, :invalid_metadata}
  end

  defp media_file(info_path) do
    base = String.trim_trailing(info_path, ".info.json")
    matches = Enum.filter(Enum.map(@extensions, &(base <> &1)), &File.regular?/1)

    case matches do
      [path] ->
        case File.lstat(path, time: :posix) do
          {:ok, %{type: :regular, size: size} = stat} when size > 0 -> {:ok, path, stat}
          _ -> {:error, :file_unavailable}
        end

      [] ->
        {:error, :missing_media}

      _ ->
        {:error, :ambiguous_media}
    end
  end

  defp unclaimed_file(path, existing) do
    id = if existing, do: existing.id, else: -1

    if Repo.exists?(from(mi in MediaItem, where: mi.media_filepath == ^path and mi.id != ^id)) do
      {:error, :path_already_used}
    else
      :ok
    end
  end

  defp import_entry(entry) do
    item = if entry.existing_id, do: Repo.get!(MediaItem, entry.existing_id), else: %MediaItem{}
    attrs = Map.put(entry.attrs, :media_downloaded_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case item |> MediaItem.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, imported} -> Pinchflat.Tasks.delete_pending_tasks_for(imported)
      {:error, _changeset} -> Repo.rollback(:invalid_media_record)
    end
  end
end
