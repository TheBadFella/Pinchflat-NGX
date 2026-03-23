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
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Pinchflat.Finch, opts) do
      {:ok, %Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Response{status: status_code}} ->
        {:error, "HTTP request failed with status code #{status_code}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{error_message(reason)}"}
    end
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp error_message(%{__exception__: true} = reason), do: Exception.message(reason)
  defp error_message(reason), do: inspect(reason)
end
