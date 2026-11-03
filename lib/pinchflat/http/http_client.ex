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

  @doc """
  Makes a GET request and returns the status, headers, and body without
  treating non-2xx responses as errors. Used by redirect-aware callers.

  Pass `max_bytes:` to read the body as a stream and abort once it exceeds that many
  bytes, returning `{:error, :too_large}`. Non-2xx responses are not read in that mode.
  """
  @impl HTTPBehaviour
  def get_with_response(url, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)
    {connect_address, request_opts} = Keyword.pop(opts, :connect_address)
    request = Finch.build(:get, url, headers)

    case connect_address do
      nil ->
        raw_request(request, request_opts)

      address when is_tuple(address) ->
        raw_request_to_address(request, address, request_opts)

      _address ->
        {:error, "HTTP request failed: invalid connection address"}
    end
  end

  @doc """
  Makes a POST request to the given URL and returns the response.
  """
  @impl HTTPBehaviour
  def post(url, headers \\ [], body \\ "", opts \\ []) do
    headers = parse_headers(headers)
    {connect_address, request_opts} = Keyword.pop(opts, :connect_address)

    case connect_address do
      nil ->
        Finch.build(:post, url, headers, body)
        |> request(request_opts)

      address when is_tuple(address) ->
        Finch.build(:post, url, headers, body)
        |> request_to_address(address, request_opts)

      _address ->
        {:error, "HTTP request failed: invalid connection address"}
    end
  end

  defp request(request, opts) do
    case raw_request(request, opts) do
      {:ok, %{status: status_code, body: body}} when status_code in 200..299 ->
        {:ok, body}

      {:ok, %{status: status_code}} ->
        {:error, "HTTP request failed with status code #{status_code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp raw_request(request, opts) do
    case Keyword.pop(opts, :max_bytes) do
      {nil, request_opts} -> buffered_request(request, request_opts)
      {max_bytes, request_opts} -> bounded_request(request, max_bytes, request_opts)
    end
  end

  # Streams the response and stops reading as soon as the body would exceed `max_bytes`,
  # so an oversized response is never held in memory. Only 2xx bodies are read: redirects
  # and error statuses are returned with their headers and an empty body.
  defp bounded_request(request, max_bytes, opts) do
    initial = %{status: nil, headers: [], chunks: [], size: 0, too_large: false}

    case Finch.stream_while(request, Pinchflat.Finch, initial, &accumulate_bounded(&1, &2, max_bytes), opts) do
      {:ok, %{too_large: true}} ->
        {:error, :too_large}

      {:ok, %{status: status, headers: headers, chunks: chunks}} ->
        {:ok, %{status: status, headers: headers, body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:error, reason, _acc} ->
        {:error, "HTTP request failed: #{error_message(reason)}"}
    end
  end

  defp accumulate_bounded({:status, status}, acc, _max_bytes), do: {:cont, %{acc | status: status}}

  defp accumulate_bounded({:headers, headers}, %{status: status} = acc, max_bytes) do
    acc = %{acc | headers: headers}

    cond do
      status not in 200..299 -> {:halt, acc}
      declared_length_over?(headers, max_bytes) -> {:halt, %{acc | too_large: true}}
      true -> {:cont, acc}
    end
  end

  defp accumulate_bounded({:data, data}, %{size: size} = acc, max_bytes) do
    new_size = size + byte_size(data)

    if new_size > max_bytes do
      {:halt, %{acc | too_large: true}}
    else
      {:cont, %{acc | size: new_size, chunks: [data | acc.chunks]}}
    end
  end

  defp accumulate_bounded(_other, acc, _max_bytes), do: {:cont, acc}

  defp declared_length_over?(headers, max_bytes) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(to_string(key)) == "content-length" and
        match?({length, _rest} when length > max_bytes, Integer.parse(to_string(value)))
    end)
  end

  defp buffered_request(request, opts) do
    case Finch.request(request, Pinchflat.Finch, opts) do
      {:ok, %Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, reason} ->
        {:error, "HTTP request failed: #{error_message(reason)}"}
    end
  end

  defp request_to_address(request, address, opts) do
    with_connected_address(request, address, &request(&1, opts))
  end

  defp raw_request_to_address(request, address, opts) do
    with_connected_address(request, address, &raw_request(&1, opts))
  end

  defp with_connected_address(request, address, fun) do
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
      |> fun.()
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
