defmodule Pinchflat.YtDlp.PluginAlertCooldown do
  @moduledoc """
  Remembers which yt-dlp plugin failures have already been alerted, so concurrent
  jobs reporting the same failure send one notification between them.

  Each call is serialised through a single process, so checking the cooldown and
  recording a claim happen as one step without any locking or retry delay.
  """

  use Agent

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc """
  Claims the alert for a failure signature unless one was claimed within the cooldown.

  Returns {:claimed, claimed_at} | :cooling_down
  """
  def claim(signature, now, cooldown_seconds) do
    Agent.get_and_update(__MODULE__, fn claims ->
      case Map.fetch(claims, signature) do
        {:ok, claimed_at} when now - claimed_at < cooldown_seconds -> {:cooling_down, claims}
        _unclaimed_or_expired -> {{:claimed, now}, Map.put(claims, signature, now)}
      end
    end)
  end

  @doc """
  Gives back a claim whose alert was not delivered, so the next report retries it.

  Only the claim made at `claimed_at` is released; a newer claim for the same
  signature is left alone.

  Returns :ok
  """
  def release(signature, claimed_at) do
    Agent.update(__MODULE__, fn claims ->
      if Map.get(claims, signature) == claimed_at, do: Map.delete(claims, signature), else: claims
    end)
  end

  @doc false
  def reset, do: Agent.update(__MODULE__, fn _claims -> %{} end)
end
