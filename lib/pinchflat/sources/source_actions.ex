defmodule Pinchflat.Sources.SourceActions do
  @moduledoc """
  Queues a source page's background actions (Download Pending, Redownload Existing,
  Force Index, Refresh Metadata and Sync Files on Disk) for several sources at once.
  """

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  @jobs [
    {:download_pending, "Download Pending"},
    {:redownload_existing, "Redownload Existing"},
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
  Download Pending and Redownload Existing skip sources with Download Media off, which is
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
  def kickoff(:force_index, source), do: SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})
  def kickoff(:refresh_metadata, source), do: SourceMetadataStorageWorker.kickoff_with_task(source)
  def kickoff(:sync_files, source), do: FileSyncingWorker.kickoff_with_task(source)

  defp bulk_kickoff(action, %Source{download_media: false}) when action in [:download_pending, :redownload_existing],
    do: :skipped

  defp bulk_kickoff(action, source), do: kickoff(action, source)

  defp tally(summary, :skipped), do: Map.update!(summary, :skipped, &(&1 + 1))
  defp tally(summary, results) when is_list(results), do: Enum.reduce(results, summary, &tally(&2, &1))
  defp tally(summary, {:ok, _task}), do: Map.update!(summary, :queued, &(&1 + 1))
  defp tally(summary, {:error, :duplicate_job}), do: Map.update!(summary, :duplicates, &(&1 + 1))
  defp tally(summary, _error), do: Map.update!(summary, :failed, &(&1 + 1))
end
