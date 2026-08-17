defmodule Pinchflat.Repo.Migrations.AddYtDlpWorkerConcurrencyToSettings do
  use Ecto.Migration

  def up do
    alter table(:settings) do
      add :yt_dlp_download_worker_concurrency, :integer
      add :yt_dlp_index_worker_concurrency, :integer
      add :yt_dlp_remote_metadata_worker_concurrency, :integer
    end

    flush()

    download = env_int(["YT_DLP_DOWNLOAD_WORKER_CONCURRENCY", "YT_DLP_WORKER_CONCURRENCY"], 5)
    index = env_int(["YT_DLP_INDEX_WORKER_CONCURRENCY", "YT_DLP_WORKER_CONCURRENCY"], 5)

    metadata =
      env_int(["YT_DLP_REMOTE_METADATA_WORKER_CONCURRENCY", "YT_DLP_WORKER_CONCURRENCY"], 5)

    execute("""
    UPDATE settings SET
      yt_dlp_download_worker_concurrency = #{download},
      yt_dlp_index_worker_concurrency = #{index},
      yt_dlp_remote_metadata_worker_concurrency = #{metadata}
    """)
  end

  def down do
    alter table(:settings) do
      remove :yt_dlp_download_worker_concurrency
      remove :yt_dlp_index_worker_concurrency
      remove :yt_dlp_remote_metadata_worker_concurrency
    end
  end

  defp env_int(keys, default) do
    keys
    |> Enum.find_value(fn key ->
      case Integer.parse(System.get_env(key, "")) do
        {value, _} -> value
        :error -> nil
      end
    end)
    |> Kernel.||(default)
    |> max(1)
    |> min(20)
  end
end
