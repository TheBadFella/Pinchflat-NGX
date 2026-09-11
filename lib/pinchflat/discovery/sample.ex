defmodule Pinchflat.Discovery.Sample do
  @moduledoc """
  Selects a bounded random display sample from a deterministically ordered pool.
  """

  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.Scoring

  @default_pool_size 50

  @doc """
  Selects at most `sample_size` candidates from at most `max_pool` candidates.

  `:random_fun` is injectable for tests and is the only source of randomness.
  """
  def select(candidates, sample_size, opts \\ []) when is_list(candidates) do
    max_pool = opts |> Keyword.get(:max_pool, @default_pool_size) |> integer_at_least_zero() |> min(@default_pool_size)
    sample_size = sample_size |> integer_at_least_zero() |> min(max_pool)
    random_fun = Keyword.get(opts, :random_fun, &Enum.take_random/2)
    score_fun = Keyword.get(opts, :score_fun, &Scoring.score/1)

    candidates
    |> Enum.filter(&match?(%Candidate{}, &1))
    |> Enum.sort_by(fn candidate -> {-score_fun.(candidate), Candidate.key(candidate)} end)
    |> Enum.take(max_pool)
    |> random_fun.(sample_size)
    |> Enum.take(sample_size)
  end

  defp integer_at_least_zero(value) when is_integer(value), do: max(value, 0)
  defp integer_at_least_zero(_value), do: 0
end
