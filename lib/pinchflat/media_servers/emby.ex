defmodule Pinchflat.MediaServers.Emby do
  @moduledoc """
  Client for triggering library scans and testing connectivity against Emby media server.

  Official reference: https://dev.emby.media/reference/RestAPI/LibraryService/postLibraryRefresh.html

  NOTE: Emby's documented POST /Library/Refresh endpoint initiates a full library scan across
  all configured libraries and requires administrator privileges. To prevent unexpected disk churn
  and full library rescans, Pinchflat requires explicit user confirmation (`emby_confirm_full_scan: true`)
  before automatic scans are triggered.
  """

  require Logger
  alias Pinchflat.HTTP.HTTPClient

  @doc """
  Triggers a full library refresh on Emby, provided full scan confirmation is granted.
  """
  def refresh(settings, _media_item \\ nil) do
    if Map.get(settings, :emby_confirm_full_scan, false) do
      with {:ok, base_url, api_key} <- extract_config(settings) do
        url = "#{base_url}/Library/Refresh"
        headers = [{"X-Emby-Token", api_key}]

        case http_client().post(url, headers, "", receive_timeout: 10_000) do
          {:ok, _body} ->
            :ok

          {:error, reason} ->
            {:error, sanitize_error(reason)}
        end
      end
    else
      {:error, :unconfirmed_full_scan,
       "Emby full library scan requires explicit confirmation in settings because Emby only supports full-library refreshes."}
    end
  end

  @doc """
  Tests connectivity and authentication with Emby.
  """
  def test_connection(settings) do
    with {:ok, base_url, api_key} <- extract_config(settings) do
      url = "#{base_url}/System/Info"
      headers = [{"X-Emby-Token", api_key}]

      case http_client().get(url, headers, receive_timeout: 10_000) do
        {:ok, _body} ->
          {:ok, :connected}

        {:error, reason} ->
          {:error, sanitize_error(reason)}
      end
    end
  end

  defp extract_config(%{emby_url: url, emby_api_key: key})
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
