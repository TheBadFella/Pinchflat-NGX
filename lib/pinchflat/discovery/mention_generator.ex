defmodule Pinchflat.Discovery.MentionGenerator do
  @moduledoc """
  Mines locally stored source descriptions and metadata for channel references.

  This generator never contacts YouTube. File sizes, source rows, text, and
  candidates are bounded so a malformed or unexpectedly large metadata file
  cannot turn a discovery scan into an unbounded read.
  """

  @behaviour Pinchflat.Discovery.Generator

  import Ecto.Query, warn: false

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Normalizer
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @default_max_sources 100
  @default_max_candidates 100
  @default_max_metadata_bytes 512 * 1024
  @default_max_text_bytes 1 * 1024 * 1024
  @absolute_max_sources 500
  @absolute_max_candidates 500
  @absolute_max_metadata_bytes 4 * 1024 * 1024
  @absolute_max_text_bytes 4 * 1024 * 1024

  @doc """
  Returns mention candidates from at most the configured number of local sources.

  `:sources` and `:read_metadata_fun` are injectable for tests and maintenance
  jobs that already have a bounded source list. The default reader accepts the
  compressed metadata files written by the existing metadata helpers.
  """
  @impl true
  def generate(opts \\ []) do
    generate_with_errors(opts).candidates
    |> Candidate.deduplicate()
    |> then(&{:ok, &1})
  end

  @doc """
  Returns candidates and safe per-source read errors without exposing metadata.
  """
  def generate_with_errors(opts \\ []) do
    max_sources =
      bounded_integer(
        Keyword.get(opts, :max_sources, default(:max_sources) || @default_max_sources),
        @default_max_sources,
        @absolute_max_sources
      )

    max_candidates =
      bounded_integer(
        Keyword.get(opts, :max_candidates, default(:max_candidates) || @default_max_candidates),
        @default_max_candidates,
        @absolute_max_candidates
      )

    max_metadata_bytes =
      bounded_integer(
        Keyword.get(opts, :max_metadata_bytes, default(:max_metadata_bytes) || @default_max_metadata_bytes),
        @default_max_metadata_bytes,
        @absolute_max_metadata_bytes
      )

    max_text_bytes =
      bounded_integer(
        Keyword.get(opts, :max_text_bytes, default(:max_text_bytes) || @default_max_text_bytes),
        @default_max_text_bytes,
        @absolute_max_text_bytes
      )

    sources = Keyword.get_lazy(opts, :sources, fn -> list_sources(max_sources) end)
    read_metadata_fun = Keyword.get(opts, :read_metadata_fun, &read_metadata/2)

    sources
    |> Enum.take(max_sources)
    |> Enum.reduce(%{candidates: [], errors: []}, fn source, result ->
      case candidates_for_source(source, read_metadata_fun, max_metadata_bytes, max_text_bytes) do
        {:ok, candidates} ->
          %{result | candidates: Enum.take(result.candidates ++ candidates, max_candidates)}

        {:error, reason} ->
          %{result | errors: [%{source_id: source_id(source), reason: safe_reason(reason)} | result.errors]}
      end
    end)
    |> Map.update!(:candidates, &Candidate.deduplicate/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  @doc """
  Extracts mention candidates from one source-like map or struct.
  """
  def candidates_for_source(
        source,
        read_metadata_fun \\ &read_metadata/2,
        max_metadata_bytes \\ @default_max_metadata_bytes,
        max_text_bytes \\ @default_max_text_bytes
      ) do
    metadata_result = read_metadata_for_source(source, read_metadata_fun, max_metadata_bytes)

    case metadata_result do
      {:ok, metadata} ->
        text =
          [source_value(source, :description), metadata]
          |> Enum.map(&text_from_term/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")
          |> truncate_bytes(max_text_bytes)

        self_references = [source_value(source, :collection_id), source_value(source, :original_url)]

        candidates =
          text
          |> Normalizer.normalize(self_references: self_references)
          |> Enum.map(&Candidate.from_reference(&1, :mention))

        {:ok, candidates}

      {:error, _reason} = error ->
        error
    end
  end

  defp list_sources(max_sources) do
    Repo.all(
      from s in Source,
        left_join: metadata in SourceMetadata,
        on: metadata.source_id == s.id,
        order_by: [asc: s.id],
        limit: ^max_sources,
        select: %{
          id: s.id,
          collection_id: s.collection_id,
          original_url: s.original_url,
          description: s.description,
          metadata_filepath: metadata.metadata_filepath
        }
    )
  end

  defp read_metadata_for_source(source, read_metadata_fun, max_metadata_bytes) do
    case source_value(source, :metadata) do
      metadata when is_map(metadata) ->
        case source_value(metadata, :metadata_filepath) do
          path when is_binary(path) and path != "" ->
            safe_read_metadata(read_metadata_fun, path, max_metadata_bytes)

          _ ->
            {:ok, metadata}
        end

      _ ->
        case source_value(source, :metadata_filepath) do
          path when is_binary(path) and path != "" ->
            safe_read_metadata(read_metadata_fun, path, max_metadata_bytes)

          _ ->
            {:ok, %{}}
        end
    end
  end

  defp safe_read_metadata(read_metadata_fun, path, max_metadata_bytes) do
    try do
      case read_metadata_fun.(path, max_metadata_bytes) do
        {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
        metadata when is_map(metadata) -> {:ok, metadata}
        {:error, reason} -> {:error, safe_reason(reason)}
        _ -> {:error, :malformed_metadata}
      end
    rescue
      _error -> {:error, :metadata_unreadable}
    catch
      :exit, _reason -> {:error, :metadata_unreadable}
    end
  end

  defp read_metadata(path, max_metadata_bytes) do
    case read_limited_compressed(path, max_metadata_bytes) do
      {:ok, json} ->
        case Phoenix.json_library().decode(json) do
          {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
          _ -> {:error, :malformed_metadata}
        end

      {:error, :not_compressed} ->
        with {:ok, stat} <- File.stat(path),
             true <- stat.size <= max_metadata_bytes,
             {:ok, json} <- File.read(path),
             {:ok, metadata} when is_map(metadata) <- Phoenix.json_library().decode(json) do
          {:ok, metadata}
        else
          _ -> {:error, :malformed_metadata}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_limited_compressed(path, max_metadata_bytes) do
    case File.open(path, [:read, :compressed, :binary]) do
      {:ok, device} ->
        result = read_at_most(device, max_metadata_bytes + 1, <<>>)
        File.close(device)

        case result do
          {:ok, data} when byte_size(data) <= max_metadata_bytes -> {:ok, data}
          {:ok, _data} -> {:error, :metadata_too_large}
          {:error, _reason} = error -> error
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :metadata_missing}

      {:error, reason} when reason in [:einval, :eisdir, :enotsup] ->
        {:error, :not_compressed}

      {:error, _reason} ->
        {:error, :metadata_unreadable}
    end
  end

  defp read_at_most(_device, remaining, acc) when remaining <= 0, do: {:ok, acc}

  defp read_at_most(device, remaining, acc) do
    case IO.binread(device, min(remaining, 64 * 1024)) do
      :eof -> {:ok, acc}
      {:error, reason} -> {:error, reason}
      data when is_binary(data) -> read_at_most(device, remaining - byte_size(data), acc <> data)
    end
  end

  defp text_from_term(value) when is_binary(value), do: value

  defp text_from_term(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.map(&text_from_term/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text_from_term(value) when is_list(value) do
    value
    |> Enum.map(&text_from_term/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text_from_term(_value), do: ""

  defp truncate_bytes(_text, max_bytes) when max_bytes <= 0, do: ""
  defp truncate_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_bytes(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> drop_incomplete_utf8()
  end

  defp drop_incomplete_utf8(prefix) do
    if String.valid?(prefix) or byte_size(prefix) == 0 do
      prefix
    else
      prefix
      |> binary_part(0, byte_size(prefix) - 1)
      |> drop_incomplete_utf8()
    end
  end

  defp source_value(source, key) when is_map(source), do: Map.get(source, key, Map.get(source, Atom.to_string(key)))

  defp source_id(source) do
    case source_value(source, :id) do
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp bounded_integer(value, _fallback, maximum) when is_integer(value), do: value |> max(0) |> min(maximum)
  defp bounded_integer(_value, fallback, maximum), do: max(fallback, 0) |> min(maximum)

  defp default(key) do
    Application.get_env(:pinchflat, :channel_discovery, [])
    |> Keyword.get(key)
  end

  defp safe_reason(reason)
       when reason in [:metadata_missing, :metadata_unreadable, :metadata_too_large, :malformed_metadata],
       do: reason

  defp safe_reason(_reason), do: :metadata_unreadable
end
