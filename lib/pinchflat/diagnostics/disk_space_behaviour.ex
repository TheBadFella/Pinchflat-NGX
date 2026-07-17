defmodule Pinchflat.Diagnostics.DiskSpaceBehaviour do
  @moduledoc """
  Behaviour for checking available disk space, so the real `df`-based
  implementation can be swapped for a mock in tests.
  """

  @callback available_bytes(Path.t()) :: {:ok, non_neg_integer()} | :error
end
