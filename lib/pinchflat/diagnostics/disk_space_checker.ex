defmodule Pinchflat.Diagnostics.DiskSpaceChecker do
  @moduledoc """
  Reports the free disk space available at a given path, using POSIX `df`.
  """

  @behaviour Pinchflat.Diagnostics.DiskSpaceBehaviour

  @doc """
  Returns the number of bytes available on the filesystem containing `path`,
  or `:error` if it can't be determined.

  Returns {:ok, non_neg_integer()} | :error
  """
  @impl Pinchflat.Diagnostics.DiskSpaceBehaviour
  def available_bytes(path) do
    case System.cmd("df", ["-P", "-k", path], stderr_to_stdout: true) do
      {output, 0} -> parse_available_kilobytes(output)
      _ -> :error
    end
  rescue
    # eg: `df` not found on the system
    ErlangError -> :error
  end

  # POSIX `df -P -k` output looks like:
  #
  #   Filesystem 1024-blocks    Used Available Capacity Mounted on
  #   /dev/vda1     41152812 9412644  29617236      25% /
  defp parse_available_kilobytes(output) do
    with [_header, data_line | _] <- String.split(output, "\n", trim: true),
         columns when length(columns) >= 4 <- String.split(data_line, ~r/\s+/, trim: true),
         {available_kb, _} <- Integer.parse(Enum.at(columns, 3)) do
      {:ok, available_kb * 1024}
    else
      _ -> :error
    end
  end
end
