defmodule Pinchflat.MediaServers.Plex do
  @moduledoc """
  Client for triggering library scans and testing connectivity against Plex Media Server.

  Official reference: https://developer.plex.tv/pms/
  """

  require Logger
  alias Pinchflat.HTTP.HTTPClient

  @doc """
  Triggers a library section refresh on Plex Media Server.
  """
  def refresh(settings, _media_item \\ nil) do
    with {:ok, base_url, token, section_id} <- extract_config(settings) do
      url = build_refresh_url(base_url, section_id)
      headers = [{"X-Plex-Token", token}]

      case http_client().get(url, headers) do
        {:ok, _body} ->
          :ok

        {:error, reason} ->
          {:error, sanitize_error(reason)}
      end
    end
  end

  @doc """
  Tests connectivity and authentication with Plex Media Server.
  """
  def test_connection(settings) do
    with {:ok, base_url, token, _section_id} <- extract_config(settings) do
      url = "#{base_url}/library/sections"
      headers = [{"X-Plex-Token", token}]

      case http_client().get(url, headers) do
        {:ok, _body} ->
          {:ok, :connected}

        {:error, reason} ->
          {:error, sanitize_error(reason)}
      end
    end
  end

  defp extract_config(%{plex_url: url, plex_token: token} = settings)
       when is_binary(url) and byte_size(url) > 0 and is_binary(token) and byte_size(token) > 0 do
    section_id = Map.get(settings, :plex_library_section_id, "all")
    section_id = if is_nil(section_id) or String.trim(section_id) == "", do: "all", else: String.trim(section_id)

    with {:ok, base_url} <- Pinchflat.MediaServers.validate_server_url(url) do
      if Regex.match?(~r/^(all|[0-9]+)$/, section_id) do
        {:ok, base_url, String.trim(token), section_id}
      else
        {:error, :invalid_library_section}
      end
    end
  end

  defp extract_config(_), do: {:error, :missing_configuration}

  defp build_refresh_url(base_url, "all") do
    "#{base_url}/library/sections/all/refresh"
  end

  defp build_refresh_url(base_url, section_id) do
    "#{base_url}/library/sections/#{URI.encode(section_id)}/refresh"
  end

  defp sanitize_error(reason) when is_binary(reason) do
    # Remove any stray token strings from error messages
    Regex.replace(~r/X-Plex-Token=[^\s&]+/i, reason, "X-Plex-Token=REDACTED")
  end

  defp sanitize_error(reason), do: inspect(reason)

  defp http_client do
    Application.get_env(:pinchflat, :http_client, HTTPClient)
  end
end
