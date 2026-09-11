defmodule Pinchflat.Discovery.Validator do
  @moduledoc """
  Validates candidates with bounded concurrency, timeouts, and result counts.

  The default validator uses the configured yt-dlp runner without cookies. A
  `:validate_fun` can be injected for tests or a future validation backend. Raw
  runner output and exception messages are converted to small atom outcomes.
  """

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Normalizer

  @default_max_results 50
  @default_max_concurrency 4
  @default_timeout 5_000
  @default_max_output_bytes 256 * 1024
  @absolute_max_results 100
  @absolute_max_concurrency 16
  @absolute_timeout 60_000
  @absolute_max_output_bytes 1 * 1024 * 1024

  @type rejection :: %{candidate: Candidate.t(), reason: atom()}
  @type result :: %{validated: [Candidate.t()], rejected: [rejection()]}

  @doc """
  Validates at most `:max_results` candidates.

  Returns `%{validated: candidates, rejected: rejection_details}`. The
  `:max_concurrency`, `:timeout`, and `:validate_fun` options are injectable.
  """
  @spec validate([Candidate.t()], keyword()) :: result()
  def validate(candidates, opts \\ []) when is_list(candidates) do
    max_results =
      bounded_integer(
        Keyword.get(opts, :max_results, default(:max_validated) || @default_max_results),
        @default_max_results,
        @absolute_max_results
      )

    max_concurrency =
      bounded_integer(
        Keyword.get(opts, :max_concurrency, default(:validation_concurrency) || @default_max_concurrency),
        @default_max_concurrency,
        @absolute_max_concurrency
      )

    timeout =
      bounded_integer(
        Keyword.get(opts, :timeout, default(:validation_timeout) || @default_timeout),
        @default_timeout,
        @absolute_timeout
      )

    max_output_bytes =
      bounded_integer(
        Keyword.get(opts, :max_output_bytes, default(:max_output_bytes) || @default_max_output_bytes),
        @default_max_output_bytes,
        @absolute_max_output_bytes
      )

    validate_fun = Keyword.get(opts, :validate_fun, &validate_with_yt_dlp/2)

    candidates = candidates |> Enum.filter(&match?(%Candidate{}, &1)) |> Enum.take(max_results)

    candidates
    |> Task.async_stream(
      fn candidate -> validate_one(candidate, validate_fun, max_output_bytes) end,
      max_concurrency: max(max_concurrency, 1),
      timeout: max(timeout, 1),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(candidates)
    |> Enum.reduce(%{validated: [], rejected: []}, fn
      {{:ok, {:validated, validated_candidate}}, _candidate}, result ->
        %{result | validated: [validated_candidate | result.validated]}

      {{:ok, {:rejected, candidate, reason}}, _original_candidate}, result ->
        %{result | rejected: [%{candidate: candidate, reason: reason} | result.rejected]}

      {{:exit, :timeout}, candidate}, result ->
        %{result | rejected: [%{candidate: candidate, reason: :timeout} | result.rejected]}

      {{:exit, _reason}, candidate}, result ->
        %{result | rejected: [%{candidate: candidate, reason: :error} | result.rejected]}
    end)
    |> then(fn result ->
      %{
        validated: result.validated |> Candidate.deduplicate() |> Enum.take(max_results),
        rejected: Enum.reverse(result.rejected)
      }
    end)
  end

  @doc """
  Alias for callers that prefer an explicit function name.
  """
  def validate_candidates(candidates, opts \\ []), do: validate(candidates, opts)

  @doc """
  Converts a validated candidate into its stable channel identity and metadata.
  """
  def normalize_validated_candidate(%Candidate{} = candidate, attrs) when is_map(attrs) do
    external_channel_id = first_value(attrs, [:external_channel_id, :channel_id, "external_channel_id", "channel_id"])
    channel_name = first_value(attrs, [:channel_name, :channel, :uploader, "channel_name", "channel", "uploader"])
    artwork_url = first_value(attrs, [:artwork_url, :thumbnail_url, "artwork_url", "thumbnail_url"])

    with true <- Normalizer.valid_channel_id?(external_channel_id),
         true <- non_empty_binary?(channel_name) do
      reference = %{
        kind: :channel_id,
        key: "channel_id:" <> external_channel_id,
        external_channel_id: external_channel_id,
        handle: nil,
        canonical_url: Normalizer.channel_url(external_channel_id)
      }

      {:ok,
       %Candidate{
         candidate
         | reference: reference,
           canonical_url: Normalizer.channel_url(external_channel_id),
           external_channel_id: external_channel_id,
           channel_name: String.trim(channel_name) |> String.slice(0, 200),
           artwork_url: bounded_artwork_url(artwork_url, candidate.artwork_url)
       }}
    else
      false -> {:error, :malformed}
    end
  end

  defp validate_one(candidate, validate_fun, max_output_bytes) do
    result =
      try do
        cond do
          is_function(validate_fun, 2) -> validate_fun.(candidate, max_output_bytes)
          is_function(validate_fun, 1) -> validate_fun.(candidate)
          true -> {:error, :error}
        end
      rescue
        _error -> {:error, :error}
      catch
        :exit, _reason -> {:error, :error}
      end

    case result do
      {:ok, %Candidate{} = validated_candidate} ->
        case validated_candidate.external_channel_id do
          id when is_binary(id) ->
            case Normalizer.valid_channel_id?(id) do
              true -> {:validated, validated_candidate}
              false -> {:rejected, candidate, :missing}
            end

          _ ->
            {:rejected, candidate, :missing}
        end

      {:ok, attrs} when is_map(attrs) ->
        case normalize_validated_candidate(candidate, attrs) do
          {:ok, validated_candidate} -> {:validated, validated_candidate}
          {:error, reason} -> {:rejected, candidate, reason}
        end

      :ok ->
        {:rejected, candidate, :malformed}

      :missing ->
        {:rejected, candidate, :missing}

      :timeout ->
        {:rejected, candidate, :timeout}

      {:timeout, _details} ->
        {:rejected, candidate, :timeout}

      {:error, reason} ->
        {:rejected, candidate, safe_reason(reason)}

      _ ->
        {:rejected, candidate, :malformed}
    end
  end

  defp validate_with_yt_dlp(%Candidate{} = candidate, max_output_bytes) do
    runner = Application.get_env(:pinchflat, :yt_dlp_runner)

    command_opts = [:simulate, :skip_download, :ignore_no_formats_error, :no_warnings, playlist_end: 1]
    output_template = "%(.{channel,channel_id,channel_url,uploader,thumbnails})j"
    addl_opts = [use_cookies: false, skip_sleep_interval: true]

    case runner.run(candidate.canonical_url, :channel_discovery_validate, command_opts, output_template, addl_opts) do
      {:ok, output} when is_binary(output) and byte_size(output) <= max_output_bytes ->
        case Phoenix.json_library().decode(String.trim(output)) do
          {:ok, response} when is_map(response) -> response
          _ -> {:error, :malformed}
        end

      {:ok, _output} ->
        {:error, :output_too_large}

      {:error, _output, _status} ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :missing}

      _ ->
        {:error, :malformed}
    end
  end

  defp first_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and byte_size(value) > 0 -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false

  defp bounded_artwork_url(value, _fallback) when is_binary(value), do: String.slice(String.trim(value), 0, 2_048)
  defp bounded_artwork_url(_value, fallback), do: fallback

  defp bounded_integer(value, _fallback, maximum) when is_integer(value), do: value |> max(0) |> min(maximum)
  defp bounded_integer(_value, fallback, maximum), do: max(fallback, 0) |> min(maximum)

  defp default(key) do
    Application.get_env(:pinchflat, :channel_discovery, [])
    |> Keyword.get(key)
  end

  defp safe_reason(reason) when reason in [:missing, :timeout, :malformed, :error, :output_too_large], do: reason
  defp safe_reason(_reason), do: :error
end
