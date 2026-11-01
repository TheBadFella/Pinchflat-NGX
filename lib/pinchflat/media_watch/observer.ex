defmodule Pinchflat.MediaWatch.Observer do
  @moduledoc """
  Fetches a normalized remote observation for a watched media item.

  Prefers the configured YouTube Data API because `videos.list` returns
  duration and privacy status in one quota-bounded call. Without an API key it
  falls back to a bounded yt-dlp metadata request with no media download.
  """

  require Logger

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @api_endpoint "https://www.googleapis.com/youtube/v3/videos"

  @doc """
  Observes a watch using the configured API key or the yt-dlp fallback.

  Returns %Observation{} (never raises for a remote failure).
  """
  def observe(watch, opts \\ []) do
    if api_key(opts), do: observe_youtube_api(watch, opts), else: observe_yt_dlp(watch, opts)
  end

  @doc "Fetches one video through the YouTube Data API."
  def observe_youtube_api(watch, opts \\ []) do
    case api_key(opts) do
      nil ->
        Observation.unknown(:youtube_api, :api_key_missing)

      key ->
        opts = Keyword.take(opts, [:connect_address])

        case http_client().get(api_url(watch.media_id, key), [accept: "application/json"], opts) do
          {:ok, body} -> decode_api_response(body, opts)
          {:error, reason} -> Observation.unknown(:youtube_api, reason)
        end
    end
  end

  @doc "Fetches one video's metadata through yt-dlp without downloading media."
  def observe_yt_dlp(watch, _opts \\ []) do
    media_item = if watch.media_item_id, do: Repo.get(MediaItem, watch.media_item_id)

    case media_item do
      %MediaItem{original_url: url} = item when is_binary(url) ->
        source = Repo.preload(item, source: :media_profile).source

        case YtDlpMedia.get_media_attributes(url, [], source: source) do
          {:ok, %YtDlpMedia{} = media} ->
            Observation.from_yt_dlp(media)

          {:error, reason, _exit_code} ->
            Observation.unknown(:yt_dlp, reason)

          {:error, reason} ->
            Observation.unknown(:yt_dlp, reason)

          {:skipped, reason} ->
            Observation.unknown(:yt_dlp, reason)

          other ->
            Logger.warning("Unexpected watch observation result: #{inspect(other)}")
            Observation.unknown(:yt_dlp, :unexpected_result)
        end

      _ ->
        Observation.unknown(:yt_dlp, :media_item_missing)
    end
  end

  defp decode_api_response(body, _opts) do
    case Jason.decode(body) do
      {:ok, %{"items" => []}} ->
        # A missing item does not establish deletion or privacy. The caller
        # treats this as unknown and retries with backoff.
        Observation.unknown(:youtube_api, :missing_item)

      {:ok, %{"items" => [item | _]}} ->
        Observation.from_youtube_api(item)

      {:ok, %{"error" => error}} ->
        Observation.unknown(:youtube_api, error)

      {:ok, _other} ->
        Observation.unknown(:youtube_api, :invalid_response)

      {:error, _reason} ->
        Observation.unknown(:youtube_api, :invalid_json)
    end
  end

  defp api_url(media_id, key) do
    query = URI.encode_query(%{"id" => media_id, "part" => "contentDetails,status,snippet", "key" => key})
    "#{@api_endpoint}?#{query}"
  end

  defp api_key(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        case Settings.get(:youtube_api_key) do
          {:ok, keys} when is_binary(keys) ->
            keys
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.find(&(&1 != ""))

          _ ->
            nil
        end
    end
  end

  defp http_client, do: Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
end
