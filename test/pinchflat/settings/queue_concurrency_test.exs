defmodule Pinchflat.Settings.QueueConcurrencyTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.Settings.QueueConcurrency

  setup do
    env_keys = [
      "YT_DLP_DOWNLOAD_WORKER_CONCURRENCY",
      "YT_DLP_INDEX_WORKER_CONCURRENCY",
      "YT_DLP_REMOTE_METADATA_WORKER_CONCURRENCY",
      "YT_DLP_WORKER_CONCURRENCY"
    ]

    originals = Map.new(env_keys, fn key -> {key, System.get_env(key)} end)
    Enum.each(env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(originals, fn
        {_key, nil} -> :ok
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "download_limit/1" do
    test "uses the stored setting when no compose env var is set" do
      setting = %{Settings.record() | yt_dlp_download_worker_concurrency: 2}

      assert QueueConcurrency.download_limit(setting) == 2
    end

    test "lets a compose env var override the stored setting" do
      setting = %{Settings.record() | yt_dlp_download_worker_concurrency: 8}
      System.put_env("YT_DLP_DOWNLOAD_WORKER_CONCURRENCY", "1")

      assert QueueConcurrency.download_limit(setting) == 1

      state = QueueConcurrency.field_states(setting).download
      assert state.locked
      assert state.env_key == "YT_DLP_DOWNLOAD_WORKER_CONCURRENCY"
      assert state.value == 1
    end

    test "falls back to the shared worker env then the default of 5" do
      setting = %{Settings.record() | yt_dlp_download_worker_concurrency: nil}

      assert QueueConcurrency.download_limit(setting) == 5

      System.put_env("YT_DLP_WORKER_CONCURRENCY", "3")
      assert QueueConcurrency.download_limit(setting) == 3
      assert QueueConcurrency.field_states(setting).download.locked
    end

    test "clamps values to 1..20" do
      setting = %{Settings.record() | yt_dlp_download_worker_concurrency: 99}

      assert QueueConcurrency.download_limit(setting) == 20
    end
  end

  describe "apply!/1" do
    test "updates the reconcile backfill ceiling from the download limit" do
      original = Application.get_env(:pinchflat, :reconcile_backfill_concurrency)
      setting = %{Settings.record() | yt_dlp_download_worker_concurrency: 4}

      assert :ok = QueueConcurrency.apply!(setting)
      assert Application.get_env(:pinchflat, :reconcile_backfill_concurrency) == 4

      Application.put_env(:pinchflat, :reconcile_backfill_concurrency, original)
    end
  end
end
