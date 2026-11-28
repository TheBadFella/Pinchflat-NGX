defmodule Pinchflat.DeletionHistory do
  @moduledoc """
  Records source deletions and media file deletions, with what caused them, so
  users can see what was removed and recover a source they deleted by mistake.
  Each deletion is also written to the log.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.DeletionHistory.DeletionEvent
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @doc """
  Records the deletion of a source and its `item_count` media items.

  Returns {:ok, %DeletionEvent{}} | {:error, term()}
  """
  def record_source_deletion(%Source{} = source, item_count, opts \\ []) do
    reason = Keyword.get(opts, :reason, :user)
    files_deleted = Keyword.get(opts, :delete_files, false)

    Logger.info(
      "Deleted source ##{source.id} #{inspect(source_name(source))} (#{source.original_url}) " <>
        "reason=#{reason} items=#{item_count} files_deleted=#{files_deleted}"
    )

    insert(%{
      kind: :source,
      reason: reason,
      source_id: source.id,
      source_name: source_name(source),
      source_url: source.original_url,
      collection_type: source.collection_type && to_string(source.collection_type),
      item_count: item_count,
      files_deleted: files_deleted
    })
  end

  @doc """
  Records the deletion of a media item's files. The source must be loaded or
  is loaded here.

  Returns {:ok, %DeletionEvent{}} | {:error, term()}
  """
  def record_media_files_deletion(%MediaItem{} = media_item, reason \\ :user) do
    source = media_item |> Repo.preload(:source) |> Map.get(:source)

    Logger.info(
      "Deleted files for media item ##{media_item.id} #{inspect(media_item.title)} (#{media_item.media_id}) " <>
        "from source ##{media_item.source_id} reason=#{reason}"
    )

    insert(%{
      kind: :media_files,
      reason: reason,
      source_id: media_item.source_id,
      source_name: source && source_name(source),
      source_url: source && source.original_url,
      collection_type: source && source.collection_type && to_string(source.collection_type),
      media_item_id: media_item.id,
      media_id: media_item.media_id,
      media_title: media_item.title,
      item_count: 1,
      files_deleted: true
    })
  end

  @doc """
  Returns a page of deletion events, newest first, and the total page count.

  Returns {[%DeletionEvent{}], integer()}
  """
  def list_page(page, per_page) when is_integer(page) and page > 0 and is_integer(per_page) and per_page > 0 do
    total = Repo.aggregate(DeletionEvent, :count, :id)

    events =
      Repo.all(
        from e in DeletionEvent,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: ^per_page,
          offset: ^((page - 1) * per_page)
      )

    {events, max(1, ceil(total / per_page))}
  end

  # Recording is best effort: a deletion that already happened must not fail.
  defp insert(attrs) do
    case %DeletionEvent{} |> Ecto.Changeset.change(attrs) |> Repo.insert() do
      {:ok, _event} = result ->
        result

      {:error, reason} = error ->
        Logger.warning("Could not record deletion: #{inspect(reason)}")
        error
    end
  end

  defp source_name(source), do: source.custom_name || source.collection_name || source.original_url
end
