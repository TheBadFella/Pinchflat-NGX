defmodule Pinchflat.LoggerFormatterTest do
  use ExUnit.Case, async: false

  alias Pinchflat.LoggerFormatter

  # A fixed UTC timestamp in Logger's tuple shape:
  # {{year, month, day}, {hour, minute, second, millisecond}}
  @utc_timestamp {{2026, 1, 15}, {18, 30, 45, 123}}

  setup do
    original = Application.get_env(:pinchflat, :timezone)
    on_exit(fn -> Application.put_env(:pinchflat, :timezone, original) end)
    :ok
  end

  defp render(timestamp) do
    LoggerFormatter.format(:info, "hello world", timestamp, [])
    |> IO.chardata_to_string()
  end

  test "renders the timestamp in the configured timezone" do
    # US/Central is UTC-6 in January (standard time), so 18:30:45 UTC -> 12:30:45
    Application.put_env(:pinchflat, :timezone, "US/Central")

    output = render(@utc_timestamp)

    assert output =~ "2026-01-15 12:30:45.123"
    assert output =~ "[info]"
    assert output =~ "hello world"
  end

  test "accounts for daylight saving time" do
    # In July, US/Central is UTC-5 (CDT), so 18:30:45 UTC -> 13:30:45
    Application.put_env(:pinchflat, :timezone, "US/Central")

    output = render({{2026, 7, 15}, {18, 30, 45, 0}})

    assert output =~ "2026-07-15 13:30:45.000"
  end

  test "leaves the timestamp untouched for UTC" do
    Application.put_env(:pinchflat, :timezone, "UTC")

    assert render(@utc_timestamp) =~ "2026-01-15 18:30:45.123"
  end

  test "falls back to UTC for an unknown timezone rather than crashing" do
    Application.put_env(:pinchflat, :timezone, "Not/AZone")

    assert render(@utc_timestamp) =~ "2026-01-15 18:30:45.123"
  end
end
