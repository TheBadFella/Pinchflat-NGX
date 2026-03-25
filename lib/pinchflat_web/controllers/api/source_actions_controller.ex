defmodule PinchflatWeb.Api.SourceActionsController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Pinchflat.Sources
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.Media.FileSyncingWorker
  alias PinchflatWeb.Schemas

  tags(["Sources"])

  operation(:download_pending,
    operation_id: "Api.SourceActionsController.download_pending",
    summary: "Download pending media",
    description: "Triggers download jobs for all pending media items in this source",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Download jobs created", "application/json", Schemas.ActionResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def download_pending(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    DownloadingHelpers.retry_pending_download_tasks(source)

    conn
    |> put_status(:ok)
    |> json(%{message: "Download jobs created for pending media items"})
  end

  operation(:redownload,
    operation_id: "Api.SourceActionsController.redownload",
    summary: "Re-download all media",
    description: "Triggers re-download jobs for all existing media items in this source",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Re-download jobs created", "application/json", Schemas.ActionResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def redownload(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    DownloadingHelpers.kickoff_redownload_for_existing_media(source)

    conn
    |> put_status(:ok)
    |> json(%{message: "Re-download jobs created for existing media items"})
  end

  operation(:index,
    operation_id: "Api.SourceActionsController.index",
    summary: "Force index source",
    description: "Triggers an indexing job to fetch the latest media from this source",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Index job created", "application/json", Schemas.ActionResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def index(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})

    conn
    |> put_status(:ok)
    |> json(%{message: "Index job created"})
  end

  operation(:refresh_metadata,
    operation_id: "Api.SourceActionsController.refresh_metadata",
    summary: "Refresh source metadata",
    description: "Triggers a job to refresh metadata for this source",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Metadata refresh job created", "application/json", Schemas.ActionResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def refresh_metadata(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    SourceMetadataStorageWorker.kickoff_with_task(source)

    conn
    |> put_status(:ok)
    |> json(%{message: "Metadata refresh job created"})
  end

  operation(:sync_files,
    operation_id: "Api.SourceActionsController.sync_files",
    summary: "Sync files to disk",
    description: "Triggers a job to sync database records with actual files on disk",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"File sync job created", "application/json", Schemas.ActionResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def sync_files(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    FileSyncingWorker.kickoff_with_task(source)

    conn
    |> put_status(:ok)
    |> json(%{message: "File sync job created"})
  end
end
