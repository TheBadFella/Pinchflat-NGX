defmodule PinchflatWeb.JobStateThrottleTest do
  use PinchflatWeb.ConnCase, async: false

  alias PinchflatWeb.JobStateThrottle

  setup do
    throttle = start_supervised!({JobStateThrottle, broadcast_interval_ms: 50, name: :test_throttle})
    PinchflatWeb.Endpoint.subscribe("job:state")

    on_exit(fn -> PinchflatWeb.Endpoint.unsubscribe("job:state") end)

    {:ok, throttle: throttle}
  end

  test "broadcasts a change event after the interval", %{throttle: throttle} do
    JobStateThrottle.notify(throttle)

    assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change", payload: nil}, 500
  end

  test "coalesces a burst of notifications into a single broadcast", %{throttle: throttle} do
    JobStateThrottle.notify(throttle)
    JobStateThrottle.notify(throttle)
    JobStateThrottle.notify(throttle)

    assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change"}, 200
  end

  test "a notification after a flush schedules a new broadcast", %{throttle: throttle} do
    JobStateThrottle.notify(throttle)
    assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change"}, 500

    JobStateThrottle.notify(throttle)
    assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change"}, 500
  end
end
