defmodule Pinchflat.YtDlp.ResponseDecoder do
  @moduledoc """
  Decodes JSON output from yt-dlp commands.

  yt-dlp writes its `--print`/`--print-to-file` template to a file that we read back and
  expect to be a single JSON document. An empty or truncated response - an extractor change,
  a geo-block, an empty/unavailable collection, or a yt-dlp behaviour change - fails to
  decode. Log the raw yt-dlp response so the underlying cause is diagnosable, then return a
  clean error tuple instead of a bare Jason.DecodeError (which callers would otherwise
  crash on via a strict `{:ok, _} =` match or a `decode!`).
  """

  require Logger

  @decode_error_message "Error decoding JSON response"

  @doc """
  Decodes a JSON response from the given yt-dlp action, logging the raw
  response (truncated) when it can't be parsed.

  Returns {:ok, map()} | {:error, binary()}
  """
  def decode(output, action) do
    case Phoenix.json_library().decode(output) do
      {:ok, parsed_json} ->
        {:ok, parsed_json}

      {:error, decode_error} ->
        Logger.error(
          "yt-dlp #{action} returned an unparseable response (#{byte_size(output)} bytes): " <>
            "#{inspect(Exception.message(decode_error))}. Raw response: #{inspect(String.slice(output, 0, 500))}"
        )

        {:error, @decode_error_message}
    end
  end

  @doc """
  Determines if the given term is a decode error produced by `decode/2`, letting
  callers reference the raw-response log line only when one was actually emitted.

  Returns boolean()
  """
  def decode_error?({:error, @decode_error_message}), do: true
  def decode_error?(_), do: false
end
