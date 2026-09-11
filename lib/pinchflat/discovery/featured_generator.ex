defmodule Pinchflat.Discovery.FeaturedGenerator do
  @moduledoc """
  Finds channels exposed by the featured tab of subscribed channels.

  Calls go through the configured yt-dlp runner, with cookies disabled and
  bounded command output. Only validated-looking channel identifiers and safe
  display metadata leave this module; raw command output is never returned or
  persisted.
  """

  @behaviour Pinchflat.Discovery.Generator

  import Ecto.Query, warn: false

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Normalizer
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @default_max_sources 50
  @default_max_candidates 100
  @default_max_entries 25
  @default_max_output_bytes 256 * 1024
  @default_timeout 15_000
  @absolute_max_sources 500
  @absolute_max_candidates 500
  @absolute_max_entries 100
  @absolute_max_output_bytes 1 * 1024 * 1024
  @absolute_timeout 60_000

  @doc """
  Queries a bounded set of subscribed channel sources for featured channels.
  """
  @impl true
  def generate(opts \\ []) do
    result = generate_with_errors(opts)

    if result.candidates == [] and result.errors != [] do
      {:error, :featured_unavailable}
    else
      {:ok, result.candidates |> Candidate.deduplicate() |> Enum.take(max_candidates(opts))}
    end
  end

  @doc """
  Returns candidates and safe per-source failures for a partial scan.
  """
  def generate_with_errors(opts \\ []) do
    max_sources =
      bounded_integer(
        Keyword.get(opts, :max_sources, default(:max_sources) || @default_max_sources),
        @default_max_sources,
        @absolute_max_sources
      )

    sources = Keyword.get_lazy(opts, :sources, fn -> list_sources(max_sources) end)

    fetch_fun =
      case Keyword.fetch(opts, :fetch_fun) do
        {:ok, fun} -> {:injected, fun}
        :error -> :default
      end

    timeout = featured_timeout(opts)

    sources
    |> Enum.take(max_sources)
    |> Enum.reduce(%{candidates: [], errors: []}, fn source, result ->
      case fetch_source(fetch_fun, source, opts, timeout) do
        {:ok, candidates} ->
          %{result | candidates: Enum.take(result.candidates ++ candidates, max_candidates(opts))}

        {:error, reason} ->
          %{result | errors: [%{source_id: source_id(source), reason: safe_reason(reason)} | result.errors]}
      end
    end)
    |> Map.update!(:candidates, &Candidate.deduplicate/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  @doc """
  Returns the `/featured` URL used for a subscribed channel.
  """
  def featured_url(%Source{} = source), do: featured_url(Map.from_struct(source))

  def featured_url(source) when is_map(source) do
    reference =
      [source_value(source, :collection_id), source_value(source, :original_url)]
      |> Enum.find_value(&Normalizer.normalize_reference/1)

    case reference do
      %{kind: :channel_id, external_channel_id: channel_id} ->
        Normalizer.channel_url(channel_id) <> "/featured"

      %{kind: :handle, handle: handle} ->
        "https://www.youtube.com/@#{handle}/featured"

      _ ->
        append_featured_suffix(source_value(source, :original_url))
    end
  end

  defp list_sources(max_sources) do
    Repo.all(
      from source in Source,
        where: source.collection_type == :channel,
        order_by: [asc: source.id],
        limit: ^max_sources
    )
  end

  defp fetch_featured(source, opts) do
    runner = Keyword.get(opts, :runner, Application.get_env(:pinchflat, :yt_dlp_runner))
    url = featured_url(source)

    max_entries =
      bounded_integer(
        Keyword.get(opts, :max_entries, default(:max_entries) || @default_max_entries),
        @default_max_entries,
        @absolute_max_entries
      )

    max_output_bytes =
      bounded_integer(
        Keyword.get(opts, :max_output_bytes, default(:max_output_bytes) || @default_max_output_bytes),
        @default_max_output_bytes,
        @absolute_max_output_bytes
      )

    command_opts = [:skip_download, :ignore_no_formats_error, :no_warnings, :flat_playlist, playlist_end: max_entries]
    addl_opts = [use_cookies: false, skip_sleep_interval: true, timeout: featured_timeout(opts)]

    with true <- is_binary(url),
         {:ok, output} <- runner.run(url, :channel_discovery_featured, command_opts, "playlist:%()j", addl_opts),
         {:ok, bounded_output} <- bounded_output(output, max_output_bytes),
         {:ok, records} <- decode_records(bounded_output, max_entries) do
      {:ok, records |> Enum.flat_map(&candidate_from_record/1) |> Enum.take(max_entries)}
    else
      false -> {:error, :source_url_missing}
      {:error, _reason, _status} -> {:error, :runner_failed}
      {:error, reason} -> {:error, safe_reason(reason)}
      _ -> {:error, :malformed_response}
    end
  end

  defp fetch_source(:default, source, opts, timeout), do: fetch_default(source, opts, timeout)
  defp fetch_source({:injected, fetch_fun}, source, opts, _timeout), do: safe_fetch(fetch_fun, source, opts)

  defp fetch_default(source, opts, timeout) do
    task = Task.async(fn -> safe_fetch(&fetch_featured/2, source, opts) end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp safe_fetch(fetch_fun, source, opts) do
    try do
      result =
        cond do
          is_function(fetch_fun, 2) -> fetch_fun.(source, opts)
          is_function(fetch_fun, 1) -> fetch_fun.(source)
          true -> {:error, :invalid_fetch_fun}
        end

      case result do
        {:ok, candidates} when is_list(candidates) -> {:ok, candidates}
        candidates when is_list(candidates) -> {:ok, candidates}
        {:error, reason} -> {:error, safe_reason(reason)}
        _ -> {:error, :malformed_response}
      end
    rescue
      _error -> {:error, :runner_failed}
    catch
      :exit, _reason -> {:error, :runner_failed}
    end
  end

  defp bounded_output(output, max_output_bytes) when is_binary(output) do
    if byte_size(output) <= max_output_bytes, do: {:ok, output}, else: {:error, :output_too_large}
  end

  defp bounded_output(_output, _max_output_bytes), do: {:error, :malformed_response}

  defp decode_records(output, max_entries) do
    trimmed_output = output |> String.trim() |> strip_output_prefix()

    case Phoenix.json_library().decode(trimmed_output) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, [decoded]}

      {:ok, decoded} when is_list(decoded) ->
        {:ok, Enum.take(decoded, max_entries)}

      _ ->
        decode_json_lines(output, max_entries)
    end
  end

  defp decode_json_lines(output, max_entries) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(max_entries)
    |> Enum.reduce_while([], fn line, records ->
      case Phoenix.json_library().decode(line |> strip_output_prefix() |> String.trim()) do
        {:ok, decoded} -> {:cont, [decoded | records]}
        _ -> {:halt, :malformed}
      end
    end)
    |> case do
      :malformed -> {:error, :malformed_response}
      [] -> {:error, :malformed_response}
      records -> {:ok, Enum.reverse(records)}
    end
  end

  defp strip_output_prefix("playlist:" <> json), do: json
  defp strip_output_prefix(json), do: json

  defp candidate_from_record(record) when is_map(record) do
    own_candidate = candidate_from_map(record)
    nested = record |> nested_records() |> Enum.flat_map(&candidate_from_record/1)
    own_candidate ++ nested
  end

  defp candidate_from_record(_record), do: []

  defp candidate_from_map(record) do
    reference_value =
      [
        Map.get(record, "channel_id"),
        Map.get(record, "channel_url"),
        Map.get(record, "uploader_url"),
        Map.get(record, "url"),
        Map.get(record, "id")
      ]
      |> Enum.find_value(&normalize_reference/1)

    case reference_value do
      nil -> []
      reference -> [Candidate.from_reference(reference, :featured, record_attrs(record))]
    end
  end

  defp nested_records(record) do
    [Map.get(record, "entries"), Map.get(record, "featured_channels"), Map.get(record, "featured")]
    |> Enum.flat_map(fn
      values when is_list(values) -> values
      value when is_map(value) -> [value]
      _ -> []
    end)
  end

  defp normalize_reference(value) when is_binary(value) do
    Normalizer.normalize_reference(value)
  end

  defp normalize_reference(_value), do: nil

  defp record_attrs(record) do
    %{
      channel_name: first_binary(record, ["channel", "channel_name", "uploader", "name", "title"]),
      artwork_url: first_artwork_url(record)
    }
  end

  defp first_binary(record, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(record, key) do
        value when is_binary(value) and byte_size(value) > 0 -> String.slice(String.trim(value), 0, 200)
        _ -> nil
      end
    end)
  end

  defp first_artwork_url(record) do
    [
      Map.get(record, "artwork_url"),
      Map.get(record, "thumbnail_url"),
      Map.get(record, "thumbnail"),
      Map.get(record, "avatar")
    ]
    |> Enum.find_value(fn value ->
      if safe_http_url?(value), do: String.slice(String.trim(value), 0, 2_048)
    end)
  end

  defp safe_http_url?(value) when is_binary(value) do
    String.starts_with?(value, "https://") or String.starts_with?(value, "http://")
  end

  defp safe_http_url?(_value), do: false

  defp append_featured_suffix(url) when is_binary(url) do
    url = String.trim_trailing(url, "/")

    base_url =
      Enum.find_value(["featured", "videos", "shorts", "streams", "live"], url, fn suffix ->
        marker = "/" <> suffix
        if String.ends_with?(url, marker), do: binary_part(url, 0, byte_size(url) - byte_size(marker))
      end)

    base_url <> "/featured"
  end

  defp append_featured_suffix(_url), do: nil

  defp source_value(source, key) when is_map(source), do: Map.get(source, key, Map.get(source, Atom.to_string(key)))

  defp source_id(source) do
    case source_value(source, :id) do
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp max_candidates(opts) do
    bounded_integer(
      Keyword.get(opts, :max_candidates, default(:max_candidates) || @default_max_candidates),
      @default_max_candidates,
      @absolute_max_candidates
    )
  end

  defp featured_timeout(opts) do
    bounded_integer(
      Keyword.get(opts, :timeout, default(:featured_timeout) || @default_timeout),
      @default_timeout,
      @absolute_timeout
    )
    |> max(1)
  end

  defp bounded_integer(value, _fallback, maximum) when is_integer(value), do: value |> max(0) |> min(maximum)
  defp bounded_integer(_value, fallback, maximum), do: max(fallback, 0) |> min(maximum)

  defp default(key) do
    Application.get_env(:pinchflat, :channel_discovery, [])
    |> Keyword.get(key)
  end

  defp safe_reason(reason)
       when reason in [:runner_failed, :malformed_response, :output_too_large, :source_url_missing, :timeout],
       do: reason

  defp safe_reason(_reason), do: :runner_failed
end
