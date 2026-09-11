defmodule Pinchflat.Discovery.Candidate do
  @moduledoc """
  An in-memory channel candidate shared by discovery generators and validation.
  """

  defstruct [
    :reference,
    :canonical_url,
    :external_channel_id,
    :channel_name,
    :artwork_url,
    evidence: nil,
    score: 0,
    generators: [],
    mentions: 0
  ]

  @type t :: %__MODULE__{
          reference: map() | nil,
          canonical_url: binary() | nil,
          external_channel_id: binary() | nil,
          channel_name: binary() | nil,
          artwork_url: binary() | nil,
          evidence: binary() | nil,
          score: non_neg_integer(),
          generators: [binary()],
          mentions: non_neg_integer()
        }

  @doc """
  Builds a candidate from a normalized channel reference.
  """
  def from_reference(reference, generator, attrs \\ %{}) when is_map(reference) do
    attrs = Map.new(attrs)
    generator = generator_name(generator)

    %__MODULE__{
      reference: reference,
      canonical_url: attr_value(attrs, :canonical_url) || Map.get(reference, :canonical_url),
      external_channel_id: attr_value(attrs, :external_channel_id) || Map.get(reference, :external_channel_id),
      channel_name: attr_value(attrs, :channel_name),
      artwork_url: attr_value(attrs, :artwork_url),
      generators: [generator],
      mentions: non_negative_integer(attr_value(attrs, :mentions) || if(generator == "mention", do: 1, else: 0))
    }
  end

  @doc """
  Merges evidence for two candidates that have the same pre-validation key.
  """
  def merge(%__MODULE__{} = first, %__MODULE__{} = second) do
    %__MODULE__{
      first
      | canonical_url: first.canonical_url || second.canonical_url,
        external_channel_id: first.external_channel_id || second.external_channel_id,
        channel_name: first.channel_name || second.channel_name,
        artwork_url: first.artwork_url || second.artwork_url,
        score: max(first.score || 0, second.score || 0),
        generators: normalize_generators(first.generators ++ second.generators),
        mentions: non_negative_integer(first.mentions) + non_negative_integer(second.mentions)
    }
  end

  @doc """
  Deduplicates candidates deterministically by the supplied key function.
  """
  def deduplicate(candidates, key_fun \\ &key/1) do
    candidates
    |> Enum.filter(&match?(%__MODULE__{}, &1))
    |> Enum.reduce(%{}, fn candidate, acc ->
      Map.update(acc, key_fun.(candidate), candidate, &merge(&1, candidate))
    end)
    |> Map.values()
    |> Enum.sort_by(fn candidate -> to_string(key_fun.(candidate)) end)
  end

  @doc """
  Returns the stable key used before validation.
  """
  def key(%__MODULE__{external_channel_id: id}) when is_binary(id), do: "channel_id:" <> id
  def key(%__MODULE__{reference: %{key: key}}) when is_binary(key), do: key
  def key(%__MODULE__{canonical_url: url}) when is_binary(url), do: url

  def key(%__MODULE__{} = candidate) do
    "candidate:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(candidate.reference)), case: :lower)
  end

  @doc """
  Adds a deterministic score to a candidate.
  """
  def with_score(%__MODULE__{} = candidate, score) when is_integer(score) and score >= 0 do
    %{candidate | score: score}
  end

  @doc """
  Returns a human-readable evidence label for display and storage.
  """
  def evidence(%__MODULE__{} = candidate) do
    candidate.generators
    |> normalize_generators()
    |> Enum.map_join(", ", fn
      "mention" -> "Mentioned in local metadata"
      "featured" -> "Featured by a subscribed channel"
      generator -> generator
    end)
  end

  defp generator_name(generator) when is_atom(generator), do: Atom.to_string(generator)
  defp generator_name(generator) when is_binary(generator), do: generator
  defp generator_name(generator), do: to_string(generator)

  defp attr_value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp normalize_generators(generators) do
    generators
    |> List.wrap()
    |> Enum.map(&generator_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp non_negative_integer(value) when is_integer(value), do: max(value, 0)
  defp non_negative_integer(_value), do: 0
end
