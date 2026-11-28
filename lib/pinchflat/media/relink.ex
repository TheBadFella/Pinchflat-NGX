defmodule Pinchflat.Media.Relink do
  @moduledoc """
  Finds media files that were moved or renamed outside Pinchflat-ngx and
  updates their recorded paths. Files are never moved, renamed or deleted.

  A scan covers a source's downloaded items whose recorded media file is
  missing. It walks the media directory once and matches each item by its
  video ID in a filename, then by the ID in an `.info.json` sidecar, and only
  then by a filename equal to the title when exactly one file has it. Items
  with no match or several candidates are reported and left unchanged.
  """

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @media_extensions ~w(.mp4 .mkv .webm .mov .m4v .avi .flv .m4a .mp3 .opus .ogg .flac .wav .aac)
  @thumbnail_extensions ~w(.jpg .jpeg .webp .png)
  @subtitle_extensions ~w(.srt .vtt .ass)
  @max_files 500_000

  @doc """
  Plans relinks for a source's items whose media file is missing.

  Each entry is `%{media_item: item, status: :matched | :ambiguous | :not_found,
  match: :video_id | :info_json | :title | nil, new_path: path | nil,
  candidates: [path], attrs: map()}`.

  Returns {:ok, [map()]} | {:error, :too_many_files}
  """
  def plan(%Source{} = source, root \\ media_directory()) do
    missing = missing_items(source)

    if missing == [] do
      {:ok, []}
    else
      with {:ok, files} <- list_files(root) do
        index = build_index(files)
        taken = recorded_paths()
        {:ok, Enum.map(missing, &plan_item(&1, index, taken))}
      end
    end
  end

  @doc """
  Applies the matched entries of a plan for the given media item IDs. Each path
  is checked again: the found file must still exist and must not be recorded
  for another item.

  Returns {:ok, relinked_count}
  """
  def apply(%Source{} = source, media_item_ids, root \\ media_directory()) do
    ids = MapSet.new(media_item_ids)

    with {:ok, entries} <- plan(source, root) do
      count =
        entries
        |> Enum.filter(&(&1.status == :matched and MapSet.member?(ids, &1.media_item.id)))
        |> Enum.count(&apply_entry/1)

      {:ok, count}
    end
  end

  defp apply_entry(%{media_item: item, new_path: path, attrs: attrs}) do
    with true <- File.regular?(path),
         false <- path_recorded_elsewhere?(path, item.id),
         {:ok, _} <- Media.update_media_item(item, attrs) do
      true
    else
      _ -> false
    end
  end

  defp missing_items(source) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> where(^MediaQuery.downloaded())
    |> order_by([mi], asc: mi.id)
    |> Repo.all()
    |> Enum.reject(&File.exists?(&1.media_filepath))
  end

  defp list_files(root) do
    files =
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: false)
      |> Stream.filter(&File.regular?/1)
      |> Enum.take(@max_files + 1)

    if length(files) > @max_files, do: {:error, :too_many_files}, else: {:ok, files}
  end

  defp build_index(files) do
    media_files = Enum.filter(files, &(String.downcase(Path.extname(&1)) in @media_extensions))

    %{
      files: MapSet.new(files),
      media_files: media_files,
      info_ids: info_json_ids(files),
      by_title: Enum.group_by(media_files, &normalize(Path.rootname(Path.basename(&1))))
    }
  end

  # Maps each info.json sidecar's video ID to the media files sharing its base name.
  defp info_json_ids(files) do
    files
    |> Enum.filter(&String.ends_with?(&1, ".info.json"))
    |> Enum.flat_map(fn path ->
      with {:ok, contents} <- File.read(path),
           {:ok, %{"id" => id}} when is_binary(id) <- Phoenix.json_library().decode(contents) do
        [{id, String.replace_suffix(path, ".info.json", "")}]
      else
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp plan_item(item, index, taken) do
    available? = &(not MapSet.member?(taken, &1) or &1 == item.media_filepath)

    {match, candidates} =
      [
        {:video_id, Enum.filter(index.media_files, &contains_id?(&1, item.media_id))},
        {:info_json, info_json_candidates(item, index)},
        {:title, title_candidates(item, index)}
      ]
      |> Enum.map(fn {match, paths} -> {match, paths |> Enum.filter(available?) |> Enum.uniq()} end)
      |> Enum.find({nil, []}, fn {_match, paths} -> paths != [] end)

    case candidates do
      [path] ->
        %{
          media_item: item,
          status: :matched,
          match: match,
          new_path: path,
          candidates: [path],
          attrs: related_attrs(path, index.files)
        }

      [] ->
        %{media_item: item, status: :not_found, match: nil, new_path: nil, candidates: [], attrs: %{}}

      paths ->
        %{media_item: item, status: :ambiguous, match: match, new_path: nil, candidates: paths, attrs: %{}}
    end
  end

  defp info_json_candidates(item, index) do
    index.info_ids
    |> Map.get(item.media_id, [])
    |> Enum.flat_map(fn base -> Enum.filter(index.media_files, &(Path.rootname(&1) == base)) end)
  end

  defp title_candidates(item, index) do
    case normalize(item.title || "") do
      "" -> []
      title -> Map.get(index.by_title, title, [])
    end
  end

  # The ID must stand alone in the name, as in "Title [dQw4w9WgXcQ].mp4".
  defp contains_id?(_path, id) when not is_binary(id) or id == "", do: false

  defp contains_id?(path, id) do
    Regex.match?(~r/(^|[^A-Za-z0-9_-])#{Regex.escape(id)}($|[^A-Za-z0-9_-])/, Path.basename(path))
  end

  defp related_attrs(media_path, files) do
    base = Path.rootname(media_path)
    sidecar = fn exts -> Enum.find_value(exts, &(MapSet.member?(files, base <> &1) && base <> &1)) end

    subtitles =
      files
      |> Enum.filter(&(String.starts_with?(&1, base <> ".") and Path.extname(&1) in @subtitle_extensions))
      |> Enum.map(fn path -> [path |> Path.rootname() |> Path.extname() |> String.trim_leading("."), path] end)
      |> Enum.reject(fn [lang, _path] -> lang == "" end)

    # Sidecars that were not found keep their recorded paths.
    %{
      media_filepath: media_path,
      thumbnail_filepath: sidecar.(@thumbnail_extensions),
      nfo_filepath: sidecar.([".nfo"]),
      subtitle_filepaths: subtitles
    }
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp recorded_paths do
    from(mi in MediaItem, where: not is_nil(mi.media_filepath), select: mi.media_filepath)
    |> Repo.all()
    |> MapSet.new()
  end

  defp path_recorded_elsewhere?(path, item_id) do
    Repo.exists?(from mi in MediaItem, where: mi.media_filepath == ^path and mi.id != ^item_id)
  end

  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")

  defp media_directory, do: Application.get_env(:pinchflat, :media_directory)
end
