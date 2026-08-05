defmodule Pinchflat.Utils.NumberUtils do
  @moduledoc """
  Utility methods for working with numbers
  """

  @doc """
  Clamps a number between a minimum and maximum value

  Returns integer() | float()
  """
  def clamp(num, minimum, maximum) do
    num
    |> max(minimum)
    |> min(maximum)
  end

  @byte_suffixes ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"]
  @byte_base 1024

  # How many decimals each unit is worth showing. Small units carry little
  # information past the decimal point (nobody cares about a tenth of a
  # megabyte), while each step up multiplies what a decimal place is worth —
  # so bigger units get more of them.
  @auto_precisions %{"B" => 0, "KiB" => 0, "MiB" => 0, "GiB" => 1, "TiB" => 2}
  @default_auto_precision 2

  @doc """
  Converts a number to a human readable byte size. Can take a precision
  option to specify the number of decimal places to round to; the default
  `:auto` picks the precision from the resulting unit (whole numbers up to
  MiB, one decimal for GiB, two for TiB and beyond).

  Returns {integer() | float(), String.t()}
  """
  def human_byte_size(number, opts \\ [])
  def human_byte_size(nil, opts), do: human_byte_size(0, opts)

  def human_byte_size(number, opts) do
    precision = Keyword.get(opts, :precision, :auto)

    scale_bytes(number / 1.0, @byte_suffixes, precision)
  end

  defp scale_bytes(value, [suffix], precision), do: {round_bytes(value, suffix, precision), suffix}

  defp scale_bytes(value, [suffix | larger_suffixes], precision) do
    if value < @byte_base do
      rounded = round_bytes(value, suffix, precision)

      # Rounding can carry into the next unit (1023.7 MiB would render as
      # "1024 MiB"), so step up a unit when it does.
      if rounded >= @byte_base do
        scale_bytes(rounded / @byte_base, larger_suffixes, precision)
      else
        {rounded, suffix}
      end
    else
      scale_bytes(value / @byte_base, larger_suffixes, precision)
    end
  end

  defp round_bytes(value, suffix, :auto) do
    round_bytes(value, suffix, Map.get(@auto_precisions, suffix, @default_auto_precision))
  end

  defp round_bytes(value, _suffix, 0), do: round(value)
  defp round_bytes(value, _suffix, precision), do: Float.round(value, precision)

  @doc """
  Adds jitter to a number based on a percentage. Returns 0 if the number is less than or equal to 0.

  Returns integer()
  """
  def add_jitter(num, jitter_percentage \\ 0.5)
  def add_jitter(num, _jitter_percentage) when num <= 0, do: 0

  def add_jitter(num, jitter_percentage) do
    jitter = :rand.uniform(round(num * jitter_percentage))

    round(num + jitter)
  end
end
