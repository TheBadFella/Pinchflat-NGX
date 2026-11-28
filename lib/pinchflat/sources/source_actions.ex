defmodule Pinchflat.Sources.SourceActions do
  @moduledoc """
  Queues a source page's background actions (Download Pending, Redownload Existing,
  Upgrade Resolution, Force Index, Refresh Metadata and Sync Files on Disk) for several sources at once,
  and starts, pauses or stops one source's downloads.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.ResolutionUpgradeWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  @jobs [
    {:download_pending, "Download Pending"},
    {:redownload_existing, "Redownload Existing"},
    {:upgrade_resolution, "Upgrade Resolution"},
    {:force_index, "Force Index"},
    {:refresh_metadata, "Refresh Metadata"},
    {:sync_files, "Sync Files on Disk"}
  ]
  @actions Keyword.keys(@jobs)

  @doc """
  Returns the actions with their button labels, in menu order.

  Returns [{atom(), String.t()}]
  """
  def jobs, do: @jobs

  @doc """
  Returns the button label for an action.
  """
  def label(action), do: Keyword.fetch!(@jobs, action)

  @doc """
  Queues `action` for each selected source, using the same jobs as the source page.
  The selection is checked like the other bulk actions (see `Sources.get_selected_sources/2`).
  Download Pending, Redownload Existing and Upgrade Resolution skip sources with Download Media off, which is
  when the source page hides them.

  Returns {:ok, %{sources: integer(), queued: integer(), duplicates: integer(), failed: integer(),
  skipped: integer()}} | {:error, :invalid_action | :invalid_selection | :unavailable_source}
  """
  def run(action, ids) when action in @actions do
    with {:ok, sources} <- Sources.get_selected_sources(ids) do
      summary = %{sources: length(sources), queued: 0, duplicates: 0, failed: 0, skipped: 0}
      {:ok, Enum.reduce(sources, summary, &tally(&2, bulk_kickoff(action, &1)))}
    end
  end

  def run(_action, _ids), do: {:error, :invalid_action}

  @doc """
  Queues `action` for one source, as its page's menu does.

  Returns what the underlying helper returns: {:ok, task}, {:error, reason} or a list of those.
  """
  def kickoff(:download_pending, source), do: DownloadingHelpers.retry_pending_download_tasks(source)
  def kickoff(:redownload_existing, source), do: DownloadingHelpers.kickoff_redownload_for_existing_media(source)
  def kickoff(:upgrade_resolution, source), do: ResolutionUpgradeWorker.kickoff_with_task(source)
  def kickoff(:force_index, source), do: SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})
  def kickoff(:refresh_metadata, source), do: SourceMetadataStorageWorker.kickoff_with_task(source)
  def kickoff(:sync_files, source), do: FileSyncingWorker.kickoff_with_task(source)

  @doc """
  Starts, pauses or stops one source's downloads, as Start All, Pause All and Stop All do.
  Start turns monitoring and downloads on when items are pending. Pause turns downloads off
  and cancels queued and running downloads; Stop also turns monitoring off. Pause and Stop
  only act while downloads are queued or running.

  Returns {:ok, %Source{}} | :nothing_to_do | {:error, %Ecto.Changeset{}}
  """
  def switch(:start, %Source{} = source) do
    if Media.list_pending_media_items_for(source) != [],
      do: Sources.update_source(source, %{enabled: true, download_media: true}),
      else: :nothing_to_do
  end

  def switch(action, %Source{} = source) when action in [:pause, :stop] do
    attrs = if action == :stop, do: %{enabled: false, download_media: false}, else: %{download_media: false}

    with true <- downloads_queued_or_running?(source),
         {:ok, source} <- Sources.update_source(source, attrs) do
      DownloadingHelpers.dequeue_pending_download_tasks(source, include_executing: true)
      {:ok, source}
    else
      false -> :nothing_to_do
      error -> error
    end
  end

  defp downloads_queued_or_running?(source) do
    from(t in Task,
      join: j in assoc(t, :job),
      join: mi in assoc(t, :media_item),
      where: mi.source_id == ^source.id,
      where: fragment("? LIKE ?", j.worker, ^"%.MediaDownloadWorker"),
      where: j.state in ["executing", "available", "scheduled", "retryable"],
      select: count(t.id)
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp bulk_kickoff(action, %Source{download_media: false})
       when action in [:download_pending, :redownload_existing, :upgrade_resolution],
       do: :skipped

  defp bulk_kickoff(action, source), do: kickoff(action, source)

  defp tally(summary, :skipped), do: Map.update!(summary, :skipped, &(&1 + 1))
  defp tally(summary, results) when is_list(results), do: Enum.reduce(results, summary, &tally(&2, &1))
  defp tally(summary, {:ok, _task}), do: Map.update!(summary, :queued, &(&1 + 1))
  defp tally(summary, {:error, :duplicate_job}), do: Map.update!(summary, :duplicates, &(&1 + 1))
  defp tally(summary, _error), do: Map.update!(summary, :failed, &(&1 + 1))
end
