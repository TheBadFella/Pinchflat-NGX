defmodule Pinchflat.YtDlp.PoTokenProvider do
  @moduledoc """
  Configuration and health checks for the optional bgutil PO-token provider.

  The provider is deliberately opt-in. When `POT_PROVIDER_URL` is absent, this
  module returns no yt-dlp options and no plugin directory option, preserving
  the existing command line and container topology.
  """

  alias Pinchflat.HTTP.HTTPClient

  @health_timeout 3_000
  @plugin_dir "/opt/pinchyt/yt-dlp-plugins"

  @doc """
  Returns typed yt-dlp extractor arguments for a configured provider.

  Returns `[]` when the provider is disabled or the configured URL is invalid.
  """
  def options do
    case valid_base_url() do
      {:ok, base_url} -> [{:extractor_args, "youtubepot-bgutilhttp:base_url=#{base_url}"}]
      :error -> []
    end
  end

  @doc """
  Returns the typed plugin-directory option when the provider is enabled and
  its bundled plugin directory is present.
  """
  def plugin_options do
    if enabled?() and plugin_directory_present?() do
      [plugin_dirs: @plugin_dir]
    else
      []
    end
  end

  @doc """
  Returns the current provider status without exposing provider response bodies.

  The provider's documented `/ping` response is considered healthy only when
  it contains both a non-empty version and a numeric server uptime. Network
  failures and malformed responses are intentionally reported separately so
  the diagnostics page stays useful without displaying sensitive data.
  """
  def status do
    case configured_url() do
      nil -> status(:disabled, "No POT_PROVIDER_URL is configured.")
      _url -> status_for_configured_provider()
    end
  end

  @doc """
  Returns a short flash-safe result for the one-click diagnostics test.
  """
  def test_result do
    case status() do
      %{state: :healthy} -> {:info, "PO-token provider is healthy."}
      %{state: :disabled} -> {:info, "PO-token provider is disabled."}
      %{state: :invalid_configuration} -> {:error, "PO-token provider configuration is invalid."}
      %{state: :invalid_response} -> {:error, "PO-token provider returned an invalid health response."}
      %{state: :unreachable} -> {:error, "PO-token provider could not be reached within the health-check timeout."}
    end
  end

  @doc false
  def enabled? do
    match?({:ok, _base_url}, valid_base_url())
  end

  defp status_for_configured_provider do
    case valid_base_url() do
      :error ->
        status(
          :invalid_configuration,
          "POT_PROVIDER_URL must be an http(s) URL without credentials or query parameters."
        )

      {:ok, base_url} ->
        health_status(base_url)
    end
  end

  defp health_status(base_url) do
    http_client().get("#{base_url}/ping", [], request_options())
    |> classify_health_response()
  end

  defp classify_health_response({:ok, body}) do
    case Jason.decode(body) do
      {:ok, %{"server_uptime" => uptime, "version" => version}}
      when is_number(uptime) and is_binary(version) and version != "" ->
        status(:healthy, "Provider responded to the documented /ping endpoint.")

      _ ->
        status(:invalid_response, "Provider did not return the documented /ping response shape.")
    end
  end

  defp classify_health_response({:error, _reason}) do
    status(:unreachable, "Provider connection failed or timed out.")
  end

  defp status(state, detail), do: %{state: state, label: label_for(state), detail: detail}

  defp label_for(:disabled), do: "Disabled"
  defp label_for(:healthy), do: "Healthy"
  defp label_for(:unreachable), do: "Unreachable"
  defp label_for(:invalid_response), do: "Invalid response"
  defp label_for(:invalid_configuration), do: "Invalid configuration"

  defp configured_url do
    case Application.get_env(:pinchflat, :po_token_provider_url) do
      url when is_binary(url) ->
        case String.trim(url) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp valid_base_url do
    with url when is_binary(url) <- configured_url(),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      {:ok, String.trim_trailing(URI.to_string(uri), "/")}
    else
      _ -> :error
    end
  end

  defp request_options do
    [pool_timeout: @health_timeout, receive_timeout: @health_timeout, request_timeout: @health_timeout]
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, HTTPClient)
  end

  defp plugin_directory_present? do
    case File.ls(@plugin_dir) do
      {:ok, [_entry | _rest]} -> true
      _ -> false
    end
  end
end
