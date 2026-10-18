defmodule Pinchflat.Lifecycle.Notifications.SourceNotifications do
  @moduledoc """
  Contains utilities for sending notifications about sources
  """

  require Logger

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @title_limit 10
  @title_length 200

  @doc """
  Wraps a function that may change the number of pending  or downloaded
  media items for a source, sending an apprise notification if
  the count changes.

  Returns the return value of the provided function
  """
  def wrap_new_media_notification(servers, source, func) do
    if Settings.get!(:notification_include_video_titles) do
      wrap_with_video_titles(servers, source, func)
    else
      wrap_without_video_titles(servers, source, func)
    end
  end

  @doc """
  Sends a notification when the count of new media items is positive.
  Optionally accepts media items whose titles are included when enabled in Settings.

  Returns :ok
  """
  def send_new_media_notification(servers, source, changed_count, media_items \\ [])

  def send_new_media_notification(_, _, count, _) when count <= 0, do: :ok

  def send_new_media_notification(servers, source, changed_count, media_items) do
    opts =
      [
        title: "[Pinchflat-ngx] New media found",
        body: notification_body(source, changed_count, media_items)
      ]

    case backend_runner().run(servers, opts) do
      {:ok, _} ->
        Logger.info("Sent new media notification for source #{source.id}")

      {:error, :no_servers} ->
        Logger.info("No notification servers provided for source #{source.id}")

      {:error, err} ->
        Logger.error("Failed to send new media notification for source #{source.id}: #{err}")
    end

    :ok
  end

  defp wrap_without_video_titles(servers, source, func) do
    before_count = relevant_media_item_count(source)
    retval = func.()
    after_count = relevant_media_item_count(source)

    send_new_media_notification(servers, source, after_count - before_count)

    retval
  end

  defp wrap_with_video_titles(servers, source, func) do
    before_ids = source |> relevant_media_items() |> select([mi], mi.id) |> Repo.all() |> MapSet.new()
    retval = func.()

    after_items =
      source
      |> relevant_media_items()
      |> select([mi], map(mi, [:id, :title, :media_id]))
      |> order_by([mi], asc: mi.id)
      |> Repo.all()

    new_media_items = Enum.reject(after_items, &MapSet.member?(before_ids, &1.id))

    send_new_media_notification(servers, source, length(after_items) - MapSet.size(before_ids), new_media_items)

    retval
  end

  defp relevant_media_items(source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.for_source(source))
    |> where(^dynamic(^MediaQuery.pending() or ^MediaQuery.downloaded()))
    |> where(^source.download_media)
  end

  defp relevant_media_item_count(source) do
    if source.download_media do
      pending_media_item_count(source) + downloaded_media_item_count(source)
    else
      0
    end
  end

  defp pending_media_item_count(source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
    |> Repo.aggregate(:count)
  end

  defp downloaded_media_item_count(source) do
    MediaQuery.new()
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
    |> Repo.aggregate(:count)
  end

  defp backend_runner do
    # This approach lets us mock the command for testing
    Application.get_env(:pinchflat, :apprise_runner)
  end

  defp notification_body(source, changed_count, media_items) do
    body = "Found #{changed_count} new media item(s) for #{source.custom_name}. Downloading them now"
    body = body <> video_titles(media_items)

    case Settings.get(:external_base_url) do
      {:ok, base_url} when is_binary(base_url) and base_url != "" ->
        "#{body}\n\n#{source_url(base_url, source)}"

      _ ->
        body
    end
  end

  defp video_titles(media_items) do
    if Settings.get!(:notification_include_video_titles) and media_items != [] do
      titles = media_items |> Enum.take(@title_limit) |> Enum.map_join("\n", &"- #{video_title(&1)}")
      remaining = length(media_items) - @title_limit
      suffix = if remaining > 0, do: "\n… and #{remaining} more", else: ""

      "\n\n#{titles}#{suffix}"
    else
      ""
    end
  end

  defp video_title(media_item) do
    title = media_item.title |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
    title = if title == "", do: media_item.media_id, else: title

    if String.length(title) > @title_length do
      String.slice(title, 0, @title_length - 1) <> "…"
    else
      title
    end
  end

  defp source_url(base_url, source) do
    "#{String.trim_trailing(base_url, "/")}/sources/#{source.id}"
  end
end
