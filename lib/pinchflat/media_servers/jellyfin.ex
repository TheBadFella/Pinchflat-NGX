defmodule Pinchflat.MediaServers.Jellyfin do
  @moduledoc """
  Client for triggering library scans and testing connectivity against Jellyfin media server.

  Official reference: https://typescript-sdk.jellyfin.org/classes/generated-client.LibraryApi.html
  """

  require Logger
  alias Pinchflat.HTTP.HTTPClient

  @doc """
  Triggers a library refresh on Jellyfin.
  """
  def refresh(settings, _media_item \\ nil) do
    with {:ok, base_url, api_key} <- extract_config(settings) do
      url = "#{base_url}/Library/Refresh"
      headers = authorization_headers(api_key)

      case http_client().post(url, headers, "", receive_timeout: 10_000) do
        {:ok, _body} ->
          :ok

        {:error, reason} ->
          {:error, sanitize_error(reason)}
      end
    end
  end

  @doc """
  Tests connectivity and authentication with Jellyfin.
  """
  def test_connection(settings) do
    with {:ok, base_url, api_key} <- extract_config(settings) do
      url = "#{base_url}/System/Info"
      headers = authorization_headers(api_key)

      case http_client().get(url, headers, receive_timeout: 10_000) do
        {:ok, _body} ->
          {:ok, :connected}

        {:error, reason} ->
          {:error, sanitize_error(reason)}
      end
    end
  end

  defp authorization_headers(api_key) do
    token = String.replace(api_key, ["\\", "\""], &("\\" <> &1))
    [{"Authorization", ~s(MediaBrowser Token="#{token}")}]
  end

  defp extract_config(%{jellyfin_url: url, jellyfin_api_key: key})
       when is_binary(url) and byte_size(url) > 0 and is_binary(key) and byte_size(key) > 0 do
    with {:ok, base_url} <- Pinchflat.MediaServers.validate_server_url(url) do
      {:ok, base_url, String.trim(key)}
    end
  end

  defp extract_config(_), do: {:error, :missing_configuration}

  defp sanitize_error(reason) when is_binary(reason) do
    Regex.replace(~r/X-Emby-Token=[^\s&]+/i, reason, "X-Emby-Token=REDACTED")
  end

  defp sanitize_error(reason), do: inspect(reason)

  defp http_client do
    Application.get_env(:pinchflat, :http_client, HTTPClient)
  end
end
