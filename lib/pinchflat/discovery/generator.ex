defmodule Pinchflat.Discovery.Generator do
  @moduledoc """
  Behaviour implemented by bounded channel discovery generators.

  Generators return in-memory candidates only. Persistence, exclusion, validation,
  scoring, and sampling belong to `Pinchflat.Discovery` so every source of
  candidates follows the same safety and identity rules.
  """

  alias Pinchflat.Discovery.Candidate

  @callback generate(keyword()) :: {:ok, [Candidate.t()]} | {:error, atom()}
end
