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
  alias PinchflatWeb.Helpers.JobActionHelpers

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
      service_unavailable: {"Some downloads could not be queued", "application/json", Schemas.ActionErrorResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def download_pending(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    result = DownloadingHelpers.retry_pending_download_tasks(source)
    JobActionHelpers.respond(conn, result, "Download jobs created for pending media items")
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
      service_unavailable: {"Some downloads could not be queued", "application/json", Schemas.ActionErrorResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def redownload(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    result = DownloadingHelpers.kickoff_redownload_for_existing_media(source)
    JobActionHelpers.respond(conn, result, "Re-download jobs created for existing media items")
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
      service_unavailable: {"Index could not be queued", "application/json", Schemas.ActionErrorResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def index(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    result = SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})
    JobActionHelpers.respond(conn, result, "Index job created")
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
      service_unavailable: {"Refresh could not be queued", "application/json", Schemas.ActionErrorResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def refresh_metadata(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    result = SourceMetadataStorageWorker.kickoff_with_task(source)
    JobActionHelpers.respond(conn, result, "Metadata refresh job created")
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
      service_unavailable: {"File sync could not be queued", "application/json", Schemas.ActionErrorResponse},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def sync_files(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    result = FileSyncingWorker.kickoff_with_task(source)
    JobActionHelpers.respond(conn, result, "File sync job created")
  end
end
