defmodule Pinchflat.Sources.PlaylistMemberships do
  @moduledoc """
  Records which of a channel's playlists each of its videos belongs to, so a
  channel source with `playlist_subfolders` can file new downloads under a
  subfolder named after the playlist.

  Every playlist a video is in is stored, in the order the channel lists its
  playlists. A video in several playlists is filed under the first one.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.PlaylistMembership
  alias Pinchflat.Sources.Source

  # Each playlist costs one yt-dlp call per index, so very large channels are capped.
  @max_playlists 100
  @insert_chunk_size 500
  @list_opts [:skip_download, :ignore_no_formats_error, :no_warnings, :flat_playlist]

  @doc """
  Fetches the channel's playlists and replaces the source's stored memberships,
  one per video per playlist. Stored memberships are kept unchanged if any
  fetch fails.

  Returns {:ok, membership_count} | {:error, reason}
  """
  def refresh(%Source{collection_type: :channel, collection_id: channel_id} = source) when is_binary(channel_id) do
    addl_opts = [use_cookies: Sources.use_cookies?(source, :indexing)]

    with {:ok, playlists} <- list_entries(playlists_url(channel_id), "%(.{id,title})j", addl_opts),
         {:ok, memberships} <- collect_memberships(Enum.take(playlists, @max_playlists), addl_opts) do
      replace_memberships(source, memberships)
    end
  end

  def refresh(_source), do: {:error, :not_a_channel}

  @doc """
  Returns the playlist title a source's video is filed under, or nil.
  """
  def playlist_title_for(source_id, media_id) when is_integer(source_id) and is_binary(media_id) do
    Repo.one(
      from m in PlaylistMembership,
        where: m.source_id == ^source_id and m.media_id == ^media_id,
        order_by: [asc: m.position],
        limit: 1,
        select: m.playlist_title
    )
  end

  def playlist_title_for(_source_id, _media_id), do: nil

  # One entry per video per playlist. `position` is the playlist's place in the
  # channel's order, so the lowest position is the first match.
  defp collect_memberships(playlists, addl_opts) do
    playlists
    |> Enum.filter(&(is_binary(&1["id"]) and is_binary(&1["title"])))
    |> Enum.uniq_by(& &1["id"])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {playlist, position}, {:ok, acc} ->
      case list_entries(playlist_url(playlist["id"]), "%(.{id})j", addl_opts) do
        {:ok, videos} ->
          entries =
            videos
            |> Enum.map(& &1["id"])
            |> Enum.filter(&is_binary/1)
            |> Enum.uniq()
            |> Enum.map(&{&1, playlist["id"], playlist["title"], position})

          {:cont, {:ok, acc ++ entries}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp replace_memberships(source, memberships) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(memberships, fn {media_id, playlist_id, title, position} ->
        %{
          source_id: source.id,
          media_id: media_id,
          playlist_id: playlist_id,
          playlist_title: title,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transaction(fn ->
      Repo.delete_all(from m in PlaylistMembership, where: m.source_id == ^source.id)

      rows
      |> Enum.chunk_every(@insert_chunk_size)
      |> Enum.each(&Repo.insert_all(PlaylistMembership, &1))

      length(rows)
    end)
  end

  defp list_entries(url, output_template, addl_opts) do
    case yt_dlp_runner().run(url, :get_playlist_memberships, @list_opts, output_template, addl_opts) do
      {:ok, output} ->
        {:ok, decode_lines(output)}

      {:error, _output, _status} = error ->
        Logger.warning("Could not list playlist entries for #{url}")
        error

      other ->
        {:error, other}
    end
  end

  defp decode_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Phoenix.json_library().decode(line) do
        {:ok, %{} = entry} -> [entry]
        _ -> []
      end
    end)
  end

  defp playlists_url(channel_id), do: "https://www.youtube.com/channel/#{channel_id}/playlists"
  defp playlist_url(playlist_id), do: "https://www.youtube.com/playlist?list=#{URI.encode_www_form(playlist_id)}"

  defp yt_dlp_runner, do: Application.get_env(:pinchflat, :yt_dlp_runner)
end
