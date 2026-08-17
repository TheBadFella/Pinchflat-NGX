defmodule Pinchflat.Settings.QueueConcurrency do
  @moduledoc """
  Resolves yt-dlp worker concurrency with a single source of truth.

  Docker Compose env vars win whenever they are set. The Settings UI then
  shows that value as read-only and tells the user to remove the variable
  from compose if they want to control it here. When the env var is absent,
  the stored setting (then a default of 5) is used.
  """

  alias Pinchflat.Settings
  alias Pinchflat.Settings.Setting

  @min 1
  @max 20
  @default 5

  @download_queue :media_fetching
  @index_queues [:fast_indexing, :media_collection_indexing]
  @metadata_queue :remote_metadata

  @download_env ["YT_DLP_DOWNLOAD_WORKER_CONCURRENCY", "YT_DLP_WORKER_CONCURRENCY"]
  @index_env ["YT_DLP_INDEX_WORKER_CONCURRENCY", "YT_DLP_WORKER_CONCURRENCY"]
  @metadata_env ["YT_DLP_REMOTE_METADATA_WORKER_CONCURRENCY", "YT_DLP_WORKER_CONCURRENCY"]

  @doc """
  Inclusive allowed range for UI-configured worker counts.
  """
  def allowed_range, do: @min..@max

  @doc """
  Effective download-queue concurrency.
  """
  def download_limit(setting \\ Settings.record()) do
    field_state(setting, :download).value
  end

  @doc """
  Effective indexing-queue concurrency (slow index + fast index).
  """
  def index_limit(setting \\ Settings.record()) do
    field_state(setting, :index).value
  end

  @doc """
  Effective remote-metadata-queue concurrency.
  """
  def metadata_limit(setting \\ Settings.record()) do
    field_state(setting, :metadata).value
  end

  @doc """
  Attributes to prefill the settings form with the effective values.
  """
  def form_attrs(%Setting{} = setting) do
    %{
      yt_dlp_download_worker_concurrency: download_limit(setting),
      yt_dlp_index_worker_concurrency: index_limit(setting),
      yt_dlp_remote_metadata_worker_concurrency: metadata_limit(setting)
    }
  end

  @doc """
  Per-field lock state for the Settings UI.

  `%{locked: true, env_key: "YT_DLP_...", value: n}` means Compose owns it.
  `%{locked: false, env_key: nil, value: n}` means the UI owns it.
  """
  def field_states(setting \\ Settings.record()) do
    %{
      download: field_state(setting, :download),
      index: field_state(setting, :index),
      metadata: field_state(setting, :metadata)
    }
  end

  @doc """
  Scales Oban queues to the effective limits and updates the reconcile
  backfill ceiling so a large online reconcile stays as polite as downloads.

  Returns :ok
  """
  def apply!(setting \\ Settings.record()) do
    download = download_limit(setting)
    index = index_limit(setting)
    metadata = metadata_limit(setting)

    Application.put_env(:pinchflat, :reconcile_backfill_concurrency, max(download, 1))

    unless oban_testing?() do
      scale!(@download_queue, download)
      Enum.each(@index_queues, &scale!(&1, index))
      scale!(@metadata_queue, metadata)
    end

    :ok
  end

  defp field_state(setting, :download) do
    resolve_field(setting.yt_dlp_download_worker_concurrency, @download_env)
  end

  defp field_state(setting, :index) do
    resolve_field(setting.yt_dlp_index_worker_concurrency, @index_env)
  end

  defp field_state(setting, :metadata) do
    resolve_field(setting.yt_dlp_remote_metadata_worker_concurrency, @metadata_env)
  end

  defp resolve_field(stored, env_keys) do
    case first_set_env(env_keys) do
      {key, value} ->
        %{locked: true, env_key: key, value: clamp(value)}

      nil ->
        %{locked: false, env_key: nil, value: stored_or_default(stored)}
    end
  end

  defp first_set_env(env_keys) do
    Enum.find_value(env_keys, fn key ->
      case parse_env(key) do
        nil -> nil
        value -> {key, value}
      end
    end)
  end

  defp stored_or_default(stored) when is_integer(stored), do: clamp(stored)
  defp stored_or_default(_stored), do: @default

  defp parse_env(key) do
    case Integer.parse(System.get_env(key, "")) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp clamp(value), do: value |> max(@min) |> min(@max)

  defp scale!(queue, limit) do
    Oban.scale_queue(queue: queue, limit: limit)
  end

  defp oban_testing? do
    case Application.get_env(:pinchflat, Oban) do
      config when is_list(config) -> Keyword.has_key?(config, :testing)
      _ -> false
    end
  end
end
