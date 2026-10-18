defmodule Pinchflat.MediaServers do
  @moduledoc """
  Media server integration context for Plex, Jellyfin, and Emby.

  Coordinates post-download library refreshes, connectivity tests, and background job dispatch.
  """

  require Logger

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.MediaServers.Emby
  alias Pinchflat.MediaServers.Jellyfin
  alias Pinchflat.MediaServers.Plex
  alias Pinchflat.MediaServers.RefreshWorker
  alias Pinchflat.Settings

  @supported_servers [:plex, :jellyfin, :emby]

  @doc """
  Returns the list of supported media server types as atoms.
  """
  def supported_servers, do: @supported_servers

  @doc "Returns a normalized HTTP server URL without embedded credentials, query or fragment."
  def validate_server_url(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(String.trim(url), "/")}

      _ ->
        {:error, :invalid_server_url}
    end
  end

  def validate_server_url(_), do: {:error, :invalid_server_url}

  @doc """
  Dispatches background refresh jobs for all enabled media servers following a successful download.
  """
  def dispatch_post_download_refresh(%MediaItem{} = media_item) do
    settings = Settings.record()
    results = []

    results =
      if settings.plex_enabled do
        [safe_enqueue_refresh(:plex, media_item) | results]
      else
        results
      end

    results =
      if settings.jellyfin_enabled do
        [safe_enqueue_refresh(:jellyfin, media_item) | results]
      else
        results
      end

    results =
      if settings.emby_enabled do
        [safe_enqueue_refresh(:emby, media_item) | results]
      else
        results
      end

    results
  rescue
    _error ->
      Logger.error("Could not dispatch media server refreshes after download")
      []
  end

  def dispatch_post_download_refresh(_), do: []

  defp safe_enqueue_refresh(server_type, media_item) do
    enqueue_refresh(server_type, media_item)
  rescue
    e ->
      Logger.error("Failed to enqueue media server refresh for #{server_type}: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Enqueues an Oban job for a specific media server refresh.
  Coalesces multiple requests for the same server into a single job.
  """
  def enqueue_refresh(server_type, _media_item \\ nil) when server_type in @supported_servers do
    args = %{
      "server_type" => to_string(server_type)
    }

    args
    |> RefreshWorker.new()
    |> Oban.insert()
  end

  @doc """
  Directly executes a library refresh against a media server.
  """
  def refresh(:plex, media_item) do
    settings = Settings.record()

    if settings.plex_enabled do
      Plex.refresh(settings, media_item)
    else
      {:error, :disabled}
    end
  end

  def refresh(:jellyfin, media_item) do
    settings = Settings.record()

    if settings.jellyfin_enabled do
      Jellyfin.refresh(settings, media_item)
    else
      {:error, :disabled}
    end
  end

  def refresh(:emby, media_item) do
    settings = Settings.record()

    if settings.emby_enabled do
      Emby.refresh(settings, media_item)
    else
      {:error, :disabled}
    end
  end

  def refresh(unsupported, _), do: {:error, {:unsupported_server, unsupported}}

  @doc """
  Tests connectivity and credentials for a given server type.
  Accepts either a settings struct/map or falls back to persisted settings.
  """
  def test_connection(server_type, custom_settings \\ nil)

  def test_connection(:plex, custom_settings) do
    settings = custom_settings || Settings.record()
    Plex.test_connection(settings)
  end

  def test_connection(:jellyfin, custom_settings) do
    settings = custom_settings || Settings.record()
    Jellyfin.test_connection(settings)
  end

  def test_connection(:emby, custom_settings) do
    settings = custom_settings || Settings.record()
    Emby.test_connection(settings)
  end

  def test_connection(unsupported, _), do: {:error, {:unsupported_server, unsupported}}
end
