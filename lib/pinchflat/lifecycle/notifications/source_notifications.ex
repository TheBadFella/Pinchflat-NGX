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
  # Keep title-enabled notifications within Pushover's 1,024-character body limit.
  # SMS providers may still segment messages. Apprise's default input format is plain text.
  @body_length 1024

  @doc """
  Wraps indexing and sends a new-media notification. With titles enabled,
  only newly inserted pending or downloaded items are counted. Otherwise,
  preserves the existing pending/downloaded count comparison.

  Returns the return value of the provided function
  """
  def wrap_new_media_notification(servers, source, func)

  def wrap_new_media_notification(_, %{download_media: false}, func), do: func.()

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
    watermark = MediaQuery.new() |> where(^MediaQuery.for_source(source)) |> Repo.aggregate(:max, :id)
    retval = func.()

    new_media_items =
      source
      |> relevant_media_items()
      |> where([mi], mi.id > ^(watermark || 0))
      # The window count uses the same snapshot and predicate as the titles, before LIMIT.
      |> select([mi], %{
        id: mi.id,
        title: mi.title,
        media_id: mi.media_id,
        uploaded_at: mi.uploaded_at,
        total: over(count(mi.id))
      })
      |> order_by([mi], desc_nulls_last: mi.uploaded_at, desc: mi.id)
      |> limit(@title_limit)
      |> Repo.all()

    count =
      case new_media_items do
        [%{total: total} | _] -> total
        [] -> 0
      end

    send_new_media_notification(servers, source, count, new_media_items)

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
    header = notification_header(source.custom_name, changed_count)
    link = notification_link(source)

    if Settings.get!(:notification_include_video_titles) do
      bounded_notification_body(source.custom_name, link, changed_count, media_items)
    else
      header <> link
    end
  end

  defp notification_header(source_name, count) do
    "Found #{count} new media item(s) for #{source_name}. Downloading them now"
  end

  defp notification_link(source) do
    case Settings.get(:external_base_url) do
      {:ok, base_url} when is_binary(base_url) and base_url != "" ->
        "\n\n#{source_url(base_url, source)}"

      _ ->
        ""
    end
  end

  defp bounded_notification_body(source_name, link, count, media_items) do
    suffix_budget = if media_items == [], do: 0, else: text_length(remaining_suffix(count, 0))
    fixed_header_length = text_length(notification_header("", count))
    # Omit an oversized URL rather than sending a broken, truncated link.
    link = if text_length(link) + suffix_budget + fixed_header_length >= @body_length, do: "", else: link
    name_budget = @body_length - fixed_header_length - text_length(link) - suffix_budget
    header = notification_header(truncate(source_name, name_budget), count)
    available = @body_length - text_length(header) - text_length(link)

    {titles, shown} =
      media_items
      |> Enum.sort_by(&{upload_timestamp(&1), Map.get(&1, :id, 0)}, :desc)
      |> Enum.take(@title_limit)
      |> Enum.reduce_while({"", 0}, fn item, {titles, shown} ->
        separator = if shown == 0, do: "\n\n", else: "\n"
        candidate = titles <> separator <> "- " <> video_title(item)

        if text_length(candidate <> remaining_suffix(count, shown + 1)) <= available do
          {:cont, {candidate, shown + 1}}
        else
          {:halt, {titles, shown}}
        end
      end)

    suffix = if media_items == [], do: "", else: remaining_suffix(count, shown)

    header <> titles <> suffix <> link
  end

  defp remaining_suffix(count, shown) when shown >= count, do: ""

  defp remaining_suffix(count, shown) do
    separator = if shown == 0, do: "\n\n", else: "\n"
    "#{separator}… and #{count - shown} more"
  end

  defp upload_timestamp(%{uploaded_at: %DateTime{} = uploaded_at}), do: DateTime.to_unix(uploaded_at)
  defp upload_timestamp(_), do: 0

  defp video_title(media_item) do
    title = media_item.title |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
    title = if title == "", do: media_item.media_id, else: title

    truncate(title, @title_length)
  end

  defp text_length(text), do: text |> String.codepoints() |> length()

  defp truncate(text, length) do
    codepoints = String.codepoints(text)

    if length(codepoints) > length do
      Enum.join(Enum.take(codepoints, length - 1)) <> "…"
    else
      text
    end
  end

  defp source_url(base_url, source) do
    "#{String.trim_trailing(base_url, "/")}/sources/#{source.id}"
  end
end
