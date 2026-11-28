defmodule Pinchflat.Sources.PlaylistFiles do
  @moduledoc """
  Writes one `.m3u` playlist file per YouTube playlist for a channel source
  with `playlist_files` on, listing the playlist's downloaded videos in the
  playlist's order. Media servers and players that read playlist files can then
  show the channel's playlists, including videos in more than one playlist.

  Files go in the folder that contains all of the source's downloads, with
  paths relative to it. Each file carries a `#PINCHFLAT-NGX-SOURCE:<id>` line;
  only files with this source's line are ever replaced or removed, so playlist
  files written by people or other sources are left alone.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.Downloading.OutputPathBuilder
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources.PlaylistMembership
  alias Pinchflat.Sources.Source

  @doc """
  Writes, updates or removes the source's playlist files to match its stored
  playlist memberships and downloaded files. With `playlist_files` off, the
  source's earlier playlist files are removed.

  Returns {:ok, written_count} | {:error, reason}
  """
  def sync(%Source{collection_type: :channel} = source) do
    downloaded = downloaded_paths(source)

    case common_directory(downloaded) do
      nil ->
        {:ok, 0}

      directory ->
        playlists = if source.playlist_files, do: playlists(source, MapSet.new(downloaded)), else: []
        written = Enum.flat_map(playlists, &write_playlist(source, directory, &1))
        remove_stale(source, directory, written)
        {:ok, length(written)}
    end
  rescue
    error in [File.Error] ->
      Logger.warning("Could not write playlist files for source ##{source.id}: #{Exception.message(error)}")
      {:error, :file_error}
  end

  def sync(_source), do: {:ok, 0}

  @doc """
  Returns the marker line that identifies a source's playlist files.
  """
  def marker(%Source{id: id}), do: "#PINCHFLAT-NGX-SOURCE:#{id}"

  defp playlists(source, downloaded) do
    from(m in PlaylistMembership,
      join: mi in MediaItem,
      on: mi.source_id == m.source_id and mi.media_id == m.media_id,
      where: m.source_id == ^source.id and not is_nil(mi.media_filepath),
      order_by: [asc: m.position, asc: m.entry_index],
      select: {m.playlist_id, m.playlist_title, mi.media_filepath, mi.title, mi.duration_seconds}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, _title, path, _item_title, _duration} -> MapSet.member?(downloaded, path) end)
    |> Enum.chunk_by(&elem(&1, 0))
    |> uniquely_named()
  end

  # Two playlists with the same title get their IDs appended so neither file is overwritten.
  defp uniquely_named(playlists) do
    duplicate_titles =
      playlists
      |> Enum.frequencies_by(fn [{_id, title, _, _, _} | _] -> file_title(title) end)
      |> Enum.filter(fn {_title, count} -> count > 1 end)
      |> MapSet.new(&elem(&1, 0))

    Enum.map(playlists, fn [{id, title, _, _, _} | _] = entries ->
      name = file_title(title)
      name = if MapSet.member?(duplicate_titles, name), do: "#{name} (#{file_title(id)})", else: name
      %{title: title, filename: name <> ".m3u", entries: entries}
    end)
  end

  defp write_playlist(source, directory, playlist) do
    path = Path.join(directory, playlist.filename)
    contents = render(source, directory, playlist)

    cond do
      File.exists?(path) and not ours?(source, path) ->
        Logger.warning("Not replacing #{path}: it was not written for source ##{source.id}")
        []

      File.exists?(path) and File.read!(path) == contents ->
        [path]

      true ->
        File.write!(path, contents)
        [path]
    end
  end

  defp render(source, directory, playlist) do
    lines =
      Enum.flat_map(playlist.entries, fn {_id, _title, media_path, item_title, duration} ->
        ["#EXTINF:#{duration || -1},#{one_line(item_title)}", Path.relative_to(media_path, directory)]
      end)

    Enum.join(["#EXTM3U", "#PLAYLIST:#{one_line(playlist.title)}", marker(source) | lines], "\n") <> "\n"
  end

  defp remove_stale(source, directory, written) do
    keep = MapSet.new(written)

    directory
    |> Path.join("*.m3u")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> Enum.filter(&ours?(source, &1))
    |> Enum.each(&File.rm/1)
  end

  defp ours?(source, path) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, "\n" <> marker(source) <> "\n")
      _ -> false
    end
  end

  defp downloaded_paths(source) do
    from(mi in MediaItem,
      where: mi.source_id == ^source.id and not is_nil(mi.media_filepath),
      select: mi.media_filepath
    )
    |> Repo.all()
    |> Enum.filter(&File.regular?/1)
  end

  defp common_directory([]), do: nil

  defp common_directory(paths) do
    paths
    |> Enum.map(&(&1 |> Path.dirname() |> Path.split()))
    |> Enum.reduce(fn parts, common ->
      common |> Enum.zip(parts) |> Enum.take_while(fn {a, b} -> a == b end) |> Enum.map(&elem(&1, 0))
    end)
    |> case do
      [] -> nil
      parts -> Path.join(parts)
    end
  end

  defp file_title(title) do
    {:literal, name} = OutputPathBuilder.literal_component(title)
    String.replace(name, "%%", "%")
  end

  defp one_line(text), do: (text || "") |> String.replace(~r/[\r\n]+/, " ") |> String.trim()
end
