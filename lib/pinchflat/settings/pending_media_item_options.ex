defmodule Pinchflat.Settings.PendingMediaItemOptions do
  @moduledoc """
  Durable handoff for item-scoped yt-dlp options submitted during single-video
  intake, before a media item exists.

  The handoff is keyed by source and video ID and consumed only after the item
  file is written and the first download is enqueued. Contents are never logged
  or exposed through an encoder.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Settings.MediaItemOptionHandoff
  alias Pinchflat.Settings.YtDlpConfigFile
  alias Pinchflat.Sources.Source

  @max_bytes 64_000

  @doc """
  Stores or replaces the pending item options for a single-video source.

  Blank contents supersede any existing handoff. Returns `{:ok, handoff}`,
  `{:ok, nil}` for a clear, or an error.
  """
  def put(%Source{} = source, media_id, contents) when is_binary(media_id) and is_binary(contents) do
    cond do
      byte_size(contents) > @max_bytes ->
        {:error, :too_large}

      String.trim(contents) == "" ->
        clear_for(source, media_id)

      true ->
        do_put(source, media_id, contents)
    end
  end

  def put(_source, _media_id, _contents), do: {:error, :invalid_contents}

  @doc """
  Fetches the current handoff for a source and video ID.

  A handoff for a different video ID is treated as stale and removed.
  """
  def fetch(%Source{id: source_id}, media_id) when is_binary(media_id) do
    case Repo.get_by(MediaItemOptionHandoff, source_id: source_id) do
      nil ->
        {:ok, nil}

      %MediaItemOptionHandoff{media_id: ^media_id} = handoff ->
        {:ok, handoff}

      %MediaItemOptionHandoff{} = stale ->
        Repo.delete(stale)
        {:ok, nil}
    end
  end

  @doc """
  Deletes any pending handoff for the item's source and video ID.
  """
  def supersede_for_item(%MediaItem{source_id: source_id, media_id: media_id}) do
    delete_where(source_id, media_id)
  end

  @doc """
  Deletes every pending handoff for a source (used when its identity changes).
  """
  def supersede_for_source(%Source{id: source_id}) do
    {_count, _} = from(h in MediaItemOptionHandoff, where: h.source_id == ^source_id) |> Repo.delete_all()
    :ok
  end

  @doc """
  Applies the pending handoff to a materialized single-video item.

  The item file is written before the first download is explicitly enqueued.
  The handoff is consumed only after queueing succeeds. Returns
  `{:ok, :none | :queued | :already_queued | :stale_source}` or an error.
  """
  def apply_for_item(%MediaItem{} = item) do
    item = Repo.preload(item, :source, force: true)
    source = item.source

    with {:ok, handoff} <- fetch(source, item.media_id) do
      cond do
        is_nil(handoff) ->
          {:ok, :none}

        source.collection_type != :video or source.collection_id != handoff.media_id ->
          supersede_for_source(source)
          {:ok, :stale_source}

        true ->
          apply_handoff(item, handoff)
      end
    end
  end

  @doc """
  Deletes the handoff only if its generation still matches the one applied.
  """
  def consume(%MediaItem{source_id: source_id, media_id: media_id}, generation)
      when is_integer(generation) do
    {count, _} =
      from(h in MediaItemOptionHandoff,
        where:
          h.source_id == ^source_id and
            h.media_id == ^media_id and
            h.generation == ^generation
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  def consume(_item, _generation), do: {:ok, 0}

  def max_bytes, do: @max_bytes

  defp do_put(%Source{id: source_id}, media_id, contents) do
    result =
      Repo.transaction(fn ->
        query = from(h in MediaItemOptionHandoff, where: h.source_id == ^source_id)
        query = if Pinchflat.Database.postgres?(), do: lock(query, "FOR UPDATE"), else: query

        case Repo.one(query) do
          nil ->
            %MediaItemOptionHandoff{}
            |> MediaItemOptionHandoff.changeset(%{
              source_id: source_id,
              media_id: media_id,
              contents: contents,
              generation: 1
            })
            |> Repo.insert()

          %MediaItemOptionHandoff{} = handoff ->
            handoff
            |> MediaItemOptionHandoff.changeset(%{
              media_id: media_id,
              contents: contents,
              generation: handoff.generation + 1
            })
            |> Repo.update()
        end
      end)

    case result do
      {:ok, {:ok, handoff}} -> {:ok, handoff}
      {:ok, {:error, changeset}} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_for(%Source{id: source_id}, media_id) do
    delete_where(source_id, media_id)
    {:ok, nil}
  end

  defp delete_where(source_id, media_id) do
    {_count, _} =
      from(h in MediaItemOptionHandoff,
        where: h.source_id == ^source_id and h.media_id == ^media_id
      )
      |> Repo.delete_all()

    :ok
  end

  defp apply_handoff(item, handoff) do
    case write_item_options(item, handoff.contents) do
      :ok ->
        case MediaDownloadWorker.kickoff_with_task(item) do
          {:ok, _task} ->
            consume(item, handoff.generation)
            {:ok, :queued}

          {:error, :duplicate_job} ->
            consume(item, handoff.generation)
            {:ok, :already_queued}

          {:error, reason} ->
            {:error, {:queue_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:file_failed, reason}}
    end
  end

  defp write_item_options(item, contents) do
    case YtDlpConfigFile.read_scope(:media_item, item.id) do
      {:ok, %{version: :missing}} ->
        save_missing_item_options(item, contents)

      {:ok, %{contents: ^contents}} ->
        :ok

      {:ok, _state} ->
        {:error, :item_config_conflict}

      {:error, :too_large, _detail} ->
        {:error, :item_config_conflict}

      {:error, :unreadable, _path} ->
        {:error, :unreadable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_missing_item_options(item, contents) do
    case YtDlpConfigFile.save_scope(:media_item, item.id, contents, :missing) do
      :ok ->
        :ok

      {:error, :stale_conflict} ->
        case YtDlpConfigFile.read_scope(:media_item, item.id) do
          {:ok, %{contents: ^contents}} -> :ok
          _ -> {:error, :stale_conflict}
        end

      other ->
        other
    end
  end
end
