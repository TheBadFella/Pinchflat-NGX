defmodule Pinchflat.YoutubeBrowser.ProviderCoordinator do
  @moduledoc """
  Coordinates provider executions with global concurrency limit (max 2),
  per-view rate limiting (max 5 ops/minute), request cancellation,
  and automatic OS child process cleanup when callers disconnect.
  """

  use GenServer
  require Logger

  @max_concurrent 2
  @rate_limit_max 5
  @rate_limit_window_ms 60_000
  @default_timeout_ms 60_000

  defstruct [
    # caller_pid => %{task_pid: pid, task_ref: ref, caller_mon: ref, from: from}
    active_slots: %{},
    # caller_pid => [timestamp1, timestamp2, ...]
    rate_limits: %{}
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes an operation function through the coordinator.
  Options:
    - `:caller`: calling process pid (defaults to self())
    - `:timeout`: timeout in ms (defaults to 60_000)
  """
  def execute(fun, opts \\ []) when is_function(fun, 0) do
    caller = Keyword.get(opts, :caller, self())
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    # Call the GenServer. Note that the coordinator replies asynchronously
    # once the worker task completes or errors.
    GenServer.call(__MODULE__, {:execute, caller, fun, timeout}, :infinity)
  end

  @doc """
  Explicitly cancels any running operation for the caller.
  """
  def cancel(caller \\ self()) do
    GenServer.call(__MODULE__, {:cancel, caller})
  end

  @doc """
  Returns current coordinator stats.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.active_slots, fn {_caller, slot} ->
      if is_pid(slot.task_pid) and Process.alive?(slot.task_pid) do
        ref = Process.monitor(slot.task_pid)
        Process.exit(slot.task_pid, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          200 -> :ok
        end
      end
    end)

    :ok
  end

  @impl true
  def handle_call({:execute, caller, fun, timeout}, from, state) do
    now = System.monotonic_time(:millisecond)

    # 1. Prune expired rate limit timestamps and dead caller PIDs
    cleaned_rate_limits = prune_rate_limits(state.rate_limits, now)

    caller_history =
      Map.get(cleaned_rate_limits, caller, [])
      |> Enum.filter(fn t -> now - t < @rate_limit_window_ms end)

    if length(caller_history) >= @rate_limit_max do
      new_rate_limits = Map.put(cleaned_rate_limits, caller, caller_history)
      {:reply, {:error, :rate_limited}, %{state | rate_limits: new_rate_limits}}
    else
      # 2. Cancel any existing operation for this caller
      state = %{state | rate_limits: cleaned_rate_limits}
      state = do_cancel_caller(state, caller)

      # 3. Check global concurrency cap
      if map_size(state.active_slots) >= @max_concurrent do
        new_rate_limits = Map.put(state.rate_limits, caller, [now | caller_history])
        {:reply, {:error, :busy}, %{state | rate_limits: new_rate_limits}}
      else
        # 4. Grant slot and start task
        caller_mon = Process.monitor(caller)

        # Spawn worker task
        coord_pid = self()

        task_pid =
          spawn_link(fn ->
            result =
              try do
                fun.()
              catch
                kind, err ->
                  {:error, {kind, err}}
              end

            send(coord_pid, {:task_done, self(), result})
          end)

        task_mon = Process.monitor(task_pid)

        # Schedule timeout timer
        timer_ref = Process.send_after(self(), {:task_timeout, task_pid}, timeout)

        slot_info = %{
          task_pid: task_pid,
          task_mon: task_mon,
          caller: caller,
          caller_mon: caller_mon,
          timer_ref: timer_ref,
          from: from
        }

        new_slots = Map.put(state.active_slots, caller, slot_info)
        new_rate_limits = Map.put(state.rate_limits, caller, [now | caller_history])

        # Do not reply immediately; reply will be sent upon task completion/timeout
        {:noreply, %{state | active_slots: new_slots, rate_limits: new_rate_limits}}
      end
    end
  end

  @impl true
  def handle_call({:cancel, caller}, _from, state) do
    new_state = do_cancel_caller(state, caller)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      active_slots: map_size(state.active_slots),
      max_concurrent: @max_concurrent
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:task_done, task_pid, result}, state) do
    case find_slot_by_task_pid(state, task_pid) do
      {caller, slot} ->
        # Cancel timeout timer and demonitor
        Process.cancel_timer(slot.timer_ref)
        Process.demonitor(slot.task_mon, [:flush])
        Process.demonitor(slot.caller_mon, [:flush])

        # Reply to caller
        GenServer.reply(slot.from, result)

        new_slots = Map.delete(state.active_slots, caller)
        {:noreply, %{state | active_slots: new_slots}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_timeout, task_pid}, state) do
    case find_slot_by_task_pid(state, task_pid) do
      {caller, slot} ->
        # Kill the task; Port will close and terminate child OS process
        ref = Process.monitor(slot.task_pid)
        Process.exit(slot.task_pid, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          100 -> :ok
        end

        # Brief grace period for OS process-tree cleanup
        Process.sleep(100)

        Process.demonitor(slot.task_mon, [:flush])
        Process.demonitor(slot.caller_mon, [:flush])

        GenServer.reply(slot.from, {:error, :timeout})

        new_slots = Map.delete(state.active_slots, caller)
        {:noreply, %{state | active_slots: new_slots}}

      nil ->
        {:noreply, state}
    end
  end

  # Task crashed unexpectedly
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      # Caller process died (e.g. LiveView disconnected)
      Map.has_key?(state.active_slots, pid) ->
        slot = Map.get(state.active_slots, pid)
        Process.cancel_timer(slot.timer_ref)
        Process.exit(slot.task_pid, :kill)
        Process.demonitor(slot.task_mon, [:flush])

        new_slots = Map.delete(state.active_slots, pid)
        new_rate_limits = Map.delete(state.rate_limits, pid)
        {:noreply, %{state | active_slots: new_slots, rate_limits: new_rate_limits}}

      # Task process died before sending result
      slot_entry = find_slot_by_task_mon(state, ref) ->
        {caller, slot} = slot_entry
        Process.cancel_timer(slot.timer_ref)
        Process.demonitor(slot.caller_mon, [:flush])

        GenServer.reply(slot.from, {:error, {:task_crashed, reason}})

        new_slots = Map.delete(state.active_slots, caller)
        {:noreply, %{state | active_slots: new_slots}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp do_cancel_caller(state, caller) do
    case Map.get(state.active_slots, caller) do
      nil ->
        state

      slot ->
        Process.cancel_timer(slot.timer_ref)
        Process.exit(slot.task_pid, :kill)
        Process.demonitor(slot.task_mon, [:flush])
        Process.demonitor(slot.caller_mon, [:flush])

        GenServer.reply(slot.from, {:error, :cancelled})
        %{state | active_slots: Map.delete(state.active_slots, caller)}
    end
  end

  defp find_slot_by_task_pid(state, task_pid) do
    Enum.find(state.active_slots, fn {_caller, slot} -> slot.task_pid == task_pid end)
  end

  defp find_slot_by_task_mon(state, task_mon) do
    Enum.find(state.active_slots, fn {_caller, slot} -> slot.task_mon == task_mon end)
  end

  defp prune_rate_limits(rate_limits, now) do
    Enum.reduce(rate_limits, %{}, fn {caller_pid, timestamps}, acc ->
      if is_pid(caller_pid) and Process.alive?(caller_pid) do
        valid = Enum.filter(timestamps, fn t -> now - t < @rate_limit_window_ms end)
        if valid == [], do: acc, else: Map.put(acc, caller_pid, valid)
      else
        acc
      end
    end)
  end
end
