defmodule Pinchflat.Downloading.MediaQualityUpgradeWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing, :suspended]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger

  alias Pinchflat.Media
  alias Pinchflat.Downloading.MediaDownloadWorker

  @doc """
  Redownloads media items that are eligible for redownload for the purpose
  of upgrading the quality of the media or improving things like sponsorblock
  segments.

  This worker is scheduled to run daily at 02:00 UTC via the Oban Cron plugin.
  With the default UTC retention schedule it runs after retention; a custom
  retention schedule or timezone may change that order. Media eligible for retention
  deletion is excluded from automatic upgrades.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Pinchflat.LegacyMigration.legacy_migration_pending?() do
      Logger.info("Legacy migration review is pending; skipping media quality upgrade")
      :ok
    else
      upgradable_media = Media.list_upgradeable_media_items()
      Logger.info("Redownloading #{length(upgradable_media)} media items")

      Enum.each(upgradable_media, fn media_item ->
        MediaDownloadWorker.kickoff_with_task(media_item, %{quality_upgrade?: true})
      end)
    end
  end
end
