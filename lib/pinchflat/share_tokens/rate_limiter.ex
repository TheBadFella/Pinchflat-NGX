defmodule Pinchflat.ShareTokens.RateLimiter do
  @moduledoc """
  Process-local in-memory rate limiter for scoped share intake endpoints.

  Enforces two distinct boundaries:
  1. Per-credential intake throughput: at most 10 requests per minute per token digest.
  2. Invalid authentication throttling: at most 20 failed auth attempts per minute per client IP.

  ### Single-node and Restart Boundary
  Counters are maintained in a local named ETS table (`:share_intake_rate_limiter`).
  Counters reset upon application restart and are scoped to the local node.
  Stale entries are pruned every 60 seconds by a background GenServer task.
  """

  use GenServer
  require Logger

  @table :share_intake_rate_limiter
  @intake_limit 10
  @invalid_auth_limit 20
  @window_seconds 60
  @cleanup_interval 60_000

  @doc """
  Starts the RateLimiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    ensure_table()
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    prune_stale_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  @doc """
  Ensures that the rate limiter ETS table exists.
  Safe to call concurrently or before GenServer starts.
  """
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Checks and increments the rate limit for a successful or in-progress intake request
  bound to a specific `token_digest`.

  Returns `:ok` or `{:error, :rate_limited, retry_after_seconds}`.
  """
  def check_intake(token_digest) when is_binary(token_digest) do
    ensure_table()
    now = System.system_time(:second)
    window_id = div(now, @window_seconds)
    key = {:intake, token_digest, window_id}

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count > @intake_limit do
      retry_after = @window_seconds - rem(now, @window_seconds)
      {:error, :rate_limited, max(1, retry_after)}
    else
      :ok
    end
  end

  @doc """
  Checks if the client IP has exceeded the threshold for invalid authentication attempts.

  Returns `:ok` or `{:error, :rate_limited, retry_after_seconds}`.
  """
  def check_invalid_auth(client_ip) do
    ensure_table()
    now = System.system_time(:second)
    window_id = div(now, @window_seconds)
    key = {:invalid_auth, normalize_ip(client_ip), window_id}

    case :ets.lookup(@table, key) do
      [{^key, count}] when count >= @invalid_auth_limit ->
        retry_after = @window_seconds - rem(now, @window_seconds)
        {:error, :rate_limited, max(1, retry_after)}

      _ ->
        :ok
    end
  end

  @doc """
  Records a failed authentication attempt against a client IP.
  """
  def record_invalid_auth(client_ip) do
    ensure_table()
    now = System.system_time(:second)
    window_id = div(now, @window_seconds)
    key = {:invalid_auth, normalize_ip(client_ip), window_id}

    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  end

  @doc """
  Prunes rate limit window buckets older than 2 minutes.
  """
  def prune_stale_entries do
    ensure_table()
    current_window = div(System.system_time(:second), @window_seconds)
    cutoff_window = current_window - 2

    match_spec = [
      {{{:"$1", :"$2", :"$3"}, :"$4"}, [{:<, :"$3", cutoff_window}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  @doc """
  Resets all rate limit state in ETS. Primarily used for testing.
  """
  def reset! do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp normalize_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp normalize_ip(ip) when is_binary(ip), do: ip
  defp normalize_ip(_), do: "unknown"

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
