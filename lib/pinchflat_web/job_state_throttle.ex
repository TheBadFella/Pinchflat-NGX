defmodule PinchflatWeb.JobStateThrottle do
  @moduledoc """
  Coalesces Oban job state-change notifications into at most one "job:state"
  broadcast per interval.

  Every job start/stop/exception fires a telemetry event, and each broadcast
  makes every subscribed LiveView (the dashboard tables) re-run its queries.
  Left unthrottled, a busy download queue triggers a flurry of redundant reads
  for each open dashboard.

  The broadcast fires at the end of the interval (trailing edge), so the final
  state of a burst of job events is always reflected.
  """

  use GenServer

  @broadcast_interval_ms 1_000
  @topic "job:state"

  def start_link(opts \\ []) do
    interval = Keyword.get(opts, :broadcast_interval_ms, @broadcast_interval_ms)
    topic = Keyword.get(opts, :topic, @topic)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, %{interval: interval, topic: topic}, name: name)
  end

  @doc """
  Notifies the throttle that a job changed state, scheduling a broadcast
  unless one is already pending.

  Returns :ok
  """
  def notify(server \\ __MODULE__) do
    GenServer.cast(server, :notify)
  end

  @impl true
  def init(%{interval: interval, topic: topic}) do
    {:ok, %{interval: interval, topic: topic, flush_scheduled: false}}
  end

  @impl true
  def handle_cast(:notify, %{flush_scheduled: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:notify, state) do
    Process.send_after(self(), :flush, state.interval)

    {:noreply, %{state | flush_scheduled: true}}
  end

  @impl true
  def handle_info(:flush, state) do
    PinchflatWeb.Endpoint.broadcast(state.topic, "change", nil)

    {:noreply, %{state | flush_scheduled: false}}
  end
end
