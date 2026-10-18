defmodule Pinchflat.YoutubeBrowser do
  @moduledoc """
  Context module for YouTube browsing, searching, details extraction,
  and bounded channel preview.
  """

  alias Pinchflat.YoutubeBrowser.Intake
  alias Pinchflat.YoutubeBrowser.ProviderCoordinator
  alias Pinchflat.YoutubeBrowser.Status

  defdelegate download_video(video_id, profile_id, opts \\ []), to: Intake
  defdelegate subscribe_channel(channel_id, profile_id, opts \\ []), to: Intake

  def provider do
    Application.get_env(
      :pinchflat,
      :youtube_browser_provider,
      Pinchflat.YoutubeBrowser.Provider.YtDlp
    )
  end

  @doc """
  Searches for YouTube videos matching the query, limited to 25 items.
  Enriches results with local library/download status.
  """
  def search_videos(query, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())
    coord_opts = [caller: caller, timeout: Keyword.get(opts, :timeout, 60_000)]

    case ProviderCoordinator.execute(fn -> provider().search_videos(query, opts) end, coord_opts) do
      {:ok, items} ->
        video_ids = Enum.map(items, & &1.id)
        statuses = Status.enrich_videos(video_ids, opts)

        enriched =
          Enum.map(items, fn item ->
            Map.put(item, :status, Map.get(statuses, item.id))
          end)

        {:ok, enriched}

      error ->
        error
    end
  end

  @doc """
  Searches for YouTube channels matching the query, limited to 25 items.
  Enriches results with local library tracking status.
  """
  def search_channels(query, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())
    coord_opts = [caller: caller, timeout: Keyword.get(opts, :timeout, 60_000)]

    case ProviderCoordinator.execute(fn -> provider().search_channels(query, opts) end, coord_opts) do
      {:ok, items} ->
        channel_ids = Enum.map(items, & &1.id)
        statuses = Status.enrich_channels(channel_ids, opts)

        enriched =
          Enum.map(items, fn item ->
            Map.put(item, :status, Map.get(statuses, item.id))
          end)

        {:ok, enriched}

      error ->
        error
    end
  end

  @doc """
  Retrieves canonical details for a single video.
  Enriches with local library status.
  """
  def get_video_details(video_id, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())
    coord_opts = [caller: caller, timeout: Keyword.get(opts, :timeout, 60_000)]

    case ProviderCoordinator.execute(fn -> provider().get_video_details(video_id, opts) end, coord_opts) do
      {:ok, detail} ->
        statuses = Status.enrich_videos([video_id], opts)
        {:ok, Map.put(detail, :status, Map.get(statuses, video_id))}

      error ->
        error
    end
  end

  @doc """
  Retrieves a bounded list of recent videos (max 25) from a channel's Videos tab.
  Enriches each video with local library status.
  """
  def get_channel_preview(channel_id_or_url, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())
    coord_opts = [caller: caller, timeout: Keyword.get(opts, :timeout, 60_000)]

    case ProviderCoordinator.execute(fn -> provider().get_channel_preview(channel_id_or_url, opts) end, coord_opts) do
      {:ok, items} ->
        video_ids = Enum.map(items, & &1.id)
        statuses = Status.enrich_videos(video_ids, opts)

        enriched =
          Enum.map(items, fn item ->
            Map.put(item, :status, Map.get(statuses, item.id))
          end)

        {:ok, enriched}

      error ->
        error
    end
  end

  @doc """
  Cancels any in-flight provider operation for the specified caller process.
  """
  def cancel_operation(caller \\ self()) do
    ProviderCoordinator.cancel(caller)
  end
end
