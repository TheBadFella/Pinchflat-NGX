defmodule Pinchflat.Settings.ScopedYtDlpOptions do
  @moduledoc """
  Shared save/rollback helpers for scoped yt-dlp option files.

  Contexts pass `:yt_dlp_options` as `:absent` or `{:present, contents}` and
  `:yt_dlp_options_version` as a SHA-256 version, `:missing`, or `:any`.
  """

  alias Pinchflat.Settings.YtDlpConfigFile

  def payload(opts), do: Keyword.get(opts, :yt_dlp_options, :absent)

  def expected_version(opts, default \\ :any) do
    Keyword.get(opts, :yt_dlp_options_version, default)
  end

  def save(:absent, _scope, _id, _expected), do: :ok

  def save({:present, contents}, scope, id, expected) do
    YtDlpConfigFile.save_scope(scope, id, contents, expected)
  end

  def save(_payload, _scope, _id, _expected), do: {:error, :invalid_options}

  @doc """
  Captures the current scoped file state before a transaction so a rolled-back
  parent write can restore it. Contents are held only in memory for this write.
  """
  def prior(scope, id) do
    case YtDlpConfigFile.read_scope(scope, id) do
      {:ok, %{contents: contents}} -> {:present, contents}
      {:error, :too_large, _detail} -> :too_large
      {:error, :unreadable, _path} -> :unreadable
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Restores the previous file only when the current file still exactly matches
  what this write attempt put there. A newer or unrelated file is never touched.
  """
  def restore(_scope, _id, _prior, :absent), do: :ok
  def restore(_scope, _id, prior, _payload) when prior in [:too_large, :unreadable], do: :ok

  def restore(scope, id, prior, {:present, attempted}) do
    case YtDlpConfigFile.read_scope(scope, id) do
      {:ok, %{contents: ^attempted}} -> do_restore(scope, id, prior)
      _ -> :ok
    end
  end

  def restore(_scope, _id, _prior, _payload), do: :ok

  defp do_restore(scope, id, :missing), do: YtDlpConfigFile.delete_scope(scope, id)

  defp do_restore(scope, id, {:present, contents}) do
    YtDlpConfigFile.save_scope(scope, id, contents, :any)
  end

  defp do_restore(_scope, _id, _prior), do: :ok
end
