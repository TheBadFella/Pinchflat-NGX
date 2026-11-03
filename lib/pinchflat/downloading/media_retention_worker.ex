defmodule Pinchflat.Downloading.MediaRetentionWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing, :suspended]],
    tags: ["media_item", "local_data"]

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media

  @doc """
  Deletes media items that are past their retention date and prevents
  them from being re-downloaded.

  This worker is scheduled via the Oban Cron plugin, daily at 01:00 by default.
  RETENTION_CRON overrides the schedule; RETENTION_TIMEZONE sets its timezone (UTC if unset).

  Returns :ok, or an error so failed filesystem deletions are retried.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Pinchflat.LegacyMigration.legacy_migration_pending?() do
      Logger.info("Legacy migration review is pending; skipping media retention culling")
      :ok
    else
      failures = cull_cullable_media_items() + delete_media_items_from_before_cutoff()
      if failures == 0, do: :ok, else: {:error, {:file_deletions_failed, failures}}
    end
  end

  defp cull_cullable_media_items do
    cullable_media =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^MediaQuery.cullable())
      |> Repo.all()

    Logger.info("Culling #{length(cullable_media)} media items past their retention date")

    Enum.count(cullable_media, fn media_item ->
      # Setting `prevent_download` does what it says on the tin, but `culled_at` is purely informational.
      # We don't actually do anything with that in terms of queries and it gets set to nil if the media item
      # gets re-downloaded.
      failed_deletion?(media_item, %{
        prevent_download: true,
        download_prevented_reason: nil,
        culled_at: DateTime.utc_now()
      })
    end)
  end

  # NOTE: Since this is a date and not a datetime, we can't add logic to have to-the-minute
  # comparison like we can with retention periods. We can only compare to the day.
  defp delete_media_items_from_before_cutoff do
    deletable_media =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:source)
      |> where(^MediaQuery.deletable_based_on_source_cutoff())
      |> Repo.all()

    Logger.info("Deleting #{length(deletable_media)} media items that are from before the source cutoff")

    Enum.count(deletable_media, fn media_item ->
      # Note that I'm not setting `prevent_download` on the media_item here.
      # That's because cutoff_date can easily change and it's a valid behavior to re-download older
      # media items if the cutoff_date changes.
      # Download is ultimately prevented because `MediaQuery.pending()` only returns media items
      # from after the cutoff date (among other things), so it's not like the media will just immediately
      # be re-downloaded.
      failed_deletion?(media_item, %{
        culled_at: DateTime.utc_now()
      })
    end)
  end

  defp failed_deletion?(media_item, attrs) do
    case Media.delete_media_files(media_item, attrs) do
      {:ok, _} ->
        false

      {:error, reason} ->
        Logger.warning("Retention did not delete item ##{media_item.id}: #{inspect(reason)}")
        true
    end
  end
end
