defmodule Pinchflat.Diagnostics.MigrationRepair.TokenStore do
  @moduledoc """
  In-memory registry for MigrationRepair preview proposals and cancellation status.
  Backed by a named ETS table.
  """

  use GenServer
  require Logger

  @table :migration_repair_tokens

  @doc """
  Starts the TokenStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @doc """
  Ensures the ETS table exists.
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
  Registers a new repair preview token.
  """
  def register(token, action, data) do
    ensure_table()
    :ets.insert(@table, {token, :active, action, data, DateTime.utc_now()})
    :ok
  end

  @doc """
  Looks up a repair token.
  Returns `{:ok, status, action, data}` or `{:error, :not_found}`.
  """
  def lookup(token) do
    ensure_table()

    case :ets.lookup(@table, token) do
      [{^token, status, action, data, _created_at}] ->
        {:ok, status, action, data}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates the status of a repair token (e.g., :cancelled or :applied).
  """
  def update_status(token, new_status) do
    ensure_table()

    case :ets.lookup(@table, token) do
      [{^token, _old_status, action, data, created_at}] ->
        :ets.insert(@table, {token, new_status, action, data, created_at})
        :ok

      [] ->
        :ets.insert(@table, {token, new_status, nil, nil, DateTime.utc_now()})
        :ok
    end
  end
end
