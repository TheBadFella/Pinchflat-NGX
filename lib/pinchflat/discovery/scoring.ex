defmodule Pinchflat.Discovery.Scoring do
  @moduledoc """
  Deterministic scoring for validated channel candidates.
  """

  alias Pinchflat.Discovery.Candidate

  @doc """
  Scores a candidate from stored evidence only. Randomness is not used here.
  """
  def score(%Candidate{} = candidate) do
    mention_points = min(non_negative_integer(candidate.mentions), 3) * 2

    generator_points =
      candidate.generators
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.reduce(0, fn
        "mention", acc -> acc + 5
        "featured", acc -> acc + 3
        _, acc -> acc
      end)

    validation_points = 2
    name_points = if non_empty_binary?(candidate.channel_name), do: 1, else: 0

    generator_points + mention_points + validation_points + name_points
  end

  @doc """
  Adds deterministic scores to candidates.
  """
  def score_candidates(candidates), do: Enum.map(candidates, &{&1, score(&1)})

  @doc """
  Returns the deterministic ordering key used by the display sampler.
  """
  def sort_key(%Candidate{} = candidate), do: {-score(candidate), Candidate.key(candidate)}

  defp non_negative_integer(value) when is_integer(value), do: max(value, 0)
  defp non_negative_integer(_value), do: 0

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false
end
