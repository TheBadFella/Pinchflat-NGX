defmodule Pinchflat.HTTP.HTTPClient do
  @moduledoc """
  This module provides a simple interface for making HTTP requests.

  Made to be easily swappable with other HTTP clients. If you need more complexity
  or security, check out HTTPoison or Mint.
  """

  alias Finch.Response
  alias Pinchflat.HTTP.HTTPBehaviour

  @behaviour HTTPBehaviour

  @doc """
  Makes a GET request to the given URL and returns the response.

  NOTE: I can't really test this with Mox and I can't think of a way to test this
  that isn't ultimately redundant. I'm just going to leave it untested for now and
  focus more on testing the consumers of this module.

  Returns {:ok, String.t()} | {:error, String.t()}
  """
  @impl HTTPBehaviour
  def get(url, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)
    {connect_address, request_opts} = Keyword.pop(opts, :connect_address)

    case connect_address do
      nil ->
        Finch.build(:get, url, headers)
        |> request(request_opts)

      address when is_tuple(address) ->
        Finch.build(:get, url, headers)
        |> request_to_address(address, request_opts)

      _address ->
        {:error, "HTTP request failed: invalid connection address"}
    end
  end

  defp request(request, opts) do
    case Finch.request(request, Pinchflat.Finch, opts) do
      {:ok, %Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Response{status: status_code}} ->
        {:error, "HTTP request failed with status code #{status_code}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{error_message(reason)}"}
    end
  end

  defp request_to_address(request, address, opts) do
    pinned_host = address_to_host(address)
    pool_tag = {:pinchflat_pinned, make_ref()}
    pool = Finch.Pool.from_name({request.scheme, pinned_host, request.port, pool_tag})

    :ok =
      Finch.start_pool(Pinchflat.Finch, pool,
        size: 1,
        count: 1,
        conn_opts: [hostname: request.host]
      )

    try do
      request
      |> Map.put(:host, pinned_host)
      |> Map.put(:pool_tag, pool_tag)
      |> request(opts)
    after
      _ = Finch.stop_pool(Pinchflat.Finch, pool)
    end
  end

  defp address_to_host({a, b, c, d} = address)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    address |> :inet.ntoa() |> to_string()
  end

  defp address_to_host({a, b, c, d, e, f, g, h} = address)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and is_integer(e) and
              is_integer(f) and is_integer(g) and is_integer(h) do
    address |> :inet.ntoa() |> to_string()
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp error_message(%{__exception__: true} = reason), do: Exception.message(reason)
  defp error_message(reason), do: inspect(reason)
end
