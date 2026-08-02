defmodule Pinchflat.LoggerFormatter do
  @moduledoc """
  A Logger format callback that renders timestamps in the application's
  configured timezone (`:pinchflat, :timezone`, resolved from the `TIMEZONE` /
  `TZ` env vars in `Pinchflat.Application`) rather than relying on the BEAM's
  OS-derived local time.

  The BEAM's built-in local time did not reliably honour `TZ` in the container
  (logs came out UTC even with `TZ` set), while the rest of the app already
  renders times correctly via the bundled Elixir `tzdata` library. This
  formatter routes log timestamps through that same mechanism so logs match the
  UI, and it honours both `TIMEZONE` and `TZ` (whichever `Application` resolved).

  Wired up in `config/config.exs` (console) and `config/runtime.exs` (file log)
  as `format: {Pinchflat.LoggerFormatter, :format}` with `utc_log: true`, so the
  timestamp handed to `format/4` is always UTC and we apply the conversion here.
  """

  # Same layout as the previous console format string. Compiled once.
  @pattern Logger.Formatter.compile("$date $time $metadata[$level] | $message\n")

  @doc """
  Logger format callback. Converts the (UTC) timestamp to the configured
  timezone, then renders using the standard formatter. Any failure falls back to
  a UTC render so a formatting error can never take the logger handler down.
  """
  def format(level, message, timestamp, metadata) do
    Logger.Formatter.format(@pattern, level, message, to_configured_timezone(timestamp), metadata)
  rescue
    _ -> "could not format log message: #{inspect({level, message, metadata})}\n"
  end

  # Timestamp arrives as {{year, month, day}, {hour, minute, second, millisecond}}
  # in UTC (handlers are configured with utc_log: true).
  defp to_configured_timezone({{_, _, _}, {_, _, _, millisecond}} = timestamp) do
    case Application.get_env(:pinchflat, :timezone) do
      tz when tz in [nil, "UTC", "Etc/UTC"] ->
        timestamp

      tz ->
        {{year, month, day}, {hour, minute, second, _}} = timestamp

        utc =
          %DateTime{
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            microsecond: {0, 0},
            std_offset: 0,
            utc_offset: 0,
            zone_abbr: "UTC",
            time_zone: "Etc/UTC"
          }

        local = Timex.Timezone.convert(utc, tz)

        {{local.year, local.month, local.day}, {local.hour, local.minute, local.second, millisecond}}
    end
  rescue
    # tzdata not started yet (very early boot), an invalid/ambiguous zone, etc.
    # Fall back to the UTC timestamp rather than crashing the log line.
    _ -> timestamp
  end
end
