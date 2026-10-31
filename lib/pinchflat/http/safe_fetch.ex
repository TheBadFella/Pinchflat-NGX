defmodule Pinchflat.HTTP.SafeFetch do
  @moduledoc """
  Fetches remote archives with SSRF protections.

  Every URL and redirect hop is checked against a host allowlist, resolved,
  and pinned to the validated address. Private, loopback, link-local, and
  reserved targets are rejected unless the host is explicitly configured and
  private addresses are opted into.
  """

  import Bitwise

  @default_hosts ~w(
    github.com
    objects.githubusercontent.com
    release-assets.githubusercontent.com
    raw.githubusercontent.com
    codeload.github.com
  )

  @allowed_schemes ~w(http https)
  @max_redirects 5
  @max_bytes 25 * 1024 * 1024
  @receive_timeout 30_000
  @request_timeout 60_000
  @user_agent "pinchflat-ngx"

  @doc """
  Returns the maximum accepted response size in bytes.
  """
  def max_bytes, do: @max_bytes

  @doc """
  Returns the built-in allowed hosts.
  """
  def default_hosts, do: @default_hosts

  @doc """
  Returns the built-in hosts combined with the configured allowlist.
  """
  def allowed_hosts do
    (@default_hosts ++ configured_hosts()) |> Enum.uniq()
  end

  @doc """
  Normalizes a comma-separated or list host allowlist.
  """
  def parse_host_list(nil), do: []

  def parse_host_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> parse_host_list()
  end

  def parse_host_list(values) when is_list(values) do
    values
    |> Enum.map(fn value -> value |> to_string() |> String.trim() |> String.downcase() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Fetches a remote archive.

  Options:
    - :dns_resolver - optional `fn host -> {:ok, [address]} | {:error, reason} end`
    - :max_redirects - maximum redirect hops
    - :max_bytes - maximum accepted body size
    - :receive_timeout - receive timeout in milliseconds
    - :request_timeout - request timeout in milliseconds

  Returns {:ok, binary()} | {:error, atom() | {:http_status, integer()}}
  """
  def fetch(url, opts \\ []) do
    fetch_url(url, opts, Keyword.get(opts, :max_redirects, @max_redirects))
  end

  defp fetch_url(url, opts, redirects_left) do
    with {:ok, uri} <- validate_url(url),
         host = String.downcase(uri.host),
         :ok <- validate_host(host),
         {:ok, address} <- resolve_address(host, opts),
         {:ok, response} <- request(URI.to_string(uri), address, opts) do
      handle_response(response, uri, opts, redirects_left)
    end
  end

  defp request(url, address, opts) do
    http_client().get_with_response(
      url,
      [{"user-agent", @user_agent}],
      connect_address: address,
      receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout),
      request_timeout: Keyword.get(opts, :request_timeout, @request_timeout)
    )
  end

  defp validate_url(url) do
    try do
      case URI.parse(String.trim(to_string(url))) do
        %URI{scheme: scheme, host: host, userinfo: nil} = uri
        when scheme in @allowed_schemes and is_binary(host) and host != "" ->
          {:ok, uri}

        _ ->
          {:error, :invalid_url}
      end
    rescue
      ArgumentError -> {:error, :invalid_url}
    end
  end

  defp validate_host(host) do
    if host in allowed_hosts(), do: :ok, else: {:error, :host_not_allowed}
  end

  defp resolve_address(host, opts) do
    resolver = Keyword.get(opts, :dns_resolver, &default_resolver/1)

    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        if Enum.any?(addresses, &private_address?/1) do
          if configured_private_allowed?(host) do
            {:ok, List.first(addresses)}
          else
            {:error, :unsafe_url}
          end
        else
          {:ok, List.first(addresses)}
        end

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :unresolvable_host}
    end
  end

  defp configured_private_allowed?(host) do
    allow_private?() and host in configured_hosts()
  end

  defp allow_private? do
    case Application.get_env(:pinchflat, :yt_dlp_plugin_url_allow_private, false) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp configured_hosts do
    Application.get_env(:pinchflat, :yt_dlp_plugin_url_allowlist, [])
    |> parse_host_list()
  end

  defp handle_response(%{status: status} = response, current_uri, opts, redirects_left)
       when status in 300..399 do
    if redirects_left <= 0 do
      {:error, :too_many_redirects}
    else
      case redirect_location(response.headers) do
        {:ok, location} ->
          next_url = URI.merge(current_uri, location) |> URI.to_string()
          fetch_url(next_url, opts, redirects_left - 1)

        :error ->
          {:error, :invalid_redirect}
      end
    end
  end

  defp handle_response(%{status: status, headers: headers, body: body}, _current_uri, opts, _redirects_left)
       when status in 200..299 do
    with :ok <- validate_content_length(headers, opts),
         :ok <- validate_body_size(body, opts) do
      {:ok, body}
    end
  end

  defp handle_response(%{status: status}, _current_uri, _opts, _redirects_left) do
    {:error, {:http_status, status}}
  end

  defp redirect_location(headers) do
    case header_value(headers, "location") do
      nil -> :error
      "" -> :error
      location -> {:ok, location}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp validate_content_length(headers, opts) do
    limit = max_bytes(opts)

    case header_value(headers, "content-length") do
      nil ->
        :ok

      value ->
        case Integer.parse(value) do
          {size, _rest} when size <= limit -> :ok
          {_size, _rest} -> {:error, :too_large}
          :error -> :ok
        end
    end
  end

  defp validate_body_size(body, opts) when is_binary(body) do
    if byte_size(body) <= max_bytes(opts), do: :ok, else: {:error, :too_large}
  end

  defp validate_body_size(_body, _opts), do: {:error, :invalid_response}

  defp max_bytes(opts), do: Keyword.get(opts, :max_bytes, @max_bytes)

  defp default_resolver(host) do
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(String.to_charlist(host), family) do
          {:ok, resolved} -> resolved
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :unresolvable_host}, else: {:ok, addresses}
  end

  defp private_address?({a, b, c, _d}) do
    a in [0, 10, 127] or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 0 and c in [0, 2]) or
      (a == 192 and b == 168) or
      (a == 198 and b in [18, 19, 51]) or
      (a == 203 and b == 0 and c == 113) or
      a >= 224
  end

  defp private_address?({a, b, c, d, e, f, g, h}) do
    ipv4_embedded? = {a, b, c, d, e} == {0, 0, 0, 0, 0} and f in [0, 65_535]

    ipv4_address =
      if ipv4_embedded? do
        {div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)}
      end

    (ipv4_embedded? && private_address?(ipv4_address)) or
      (a == 0 and Enum.all?([b, c, d, e, f, g], &(&1 == 0)) and h in [0, 1]) or
      (a &&& 0xFE00) == 0xFC00 or
      (a &&& 0xFFC0) == 0xFE80 or
      (a &&& 0xFF00) == 0xFF00
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
