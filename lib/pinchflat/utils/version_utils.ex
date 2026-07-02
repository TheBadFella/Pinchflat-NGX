defmodule Pinchflat.Utils.VersionUtils do
  @moduledoc """
  Utilities for comparing yt-dlp version strings.

  yt-dlp uses date-based versions (`YYYY.MM.DD` for stable, `YYYY.MM.DD.NNNNNN`
  for nightly builds) for both channels, so a component-wise numeric comparison
  is reliable. A same-day nightly sorts _after_ that day's stable release because
  it carries an extra trailing component.
  """

  @doc """
  Compares two date-based yt-dlp versions.

  Missing trailing components are treated as zero, so `"2025.07.01"` is considered
  equal to `"2025.07.01.0"` and less than `"2025.07.01.123456"`.

  Returns `:lt | :eq | :gt`
  """
  def compare(left, right) do
    do_compare(parse(left), parse(right))
  end

  defp parse(version) do
    version
    |> to_string()
    |> String.trim()
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {int, _} -> int
        :error -> 0
      end
    end)
  end

  defp do_compare([], []), do: :eq
  defp do_compare([head | left], []), do: if(head == 0, do: do_compare(left, []), else: :gt)
  defp do_compare([], [head | right]), do: if(head == 0, do: do_compare([], right), else: :lt)

  defp do_compare([head | left], [head | right]), do: do_compare(left, right)
  defp do_compare([left | _], [right | _]) when left > right, do: :gt
  defp do_compare(_, _), do: :lt
end
