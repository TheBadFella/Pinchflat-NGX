defmodule PinchflatWeb.Api.TaskController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ecto.Query, warn: false

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias PinchflatWeb.Schemas

  tags(["Tasks"])

  operation(:index,
    operation_id: "Api.TaskController.index",
    summary: "List tasks",
    description: "Returns a list of background tasks with optional filtering",
    parameters: [
      source_id: [in: :query, description: "Filter by source ID", schema: %Schema{type: :integer}],
      media_item_id: [in: :query, description: "Filter by media item ID", schema: %Schema{type: :integer}],
      worker: [
        in: :query,
        description: "Filter by worker name (e.g., 'MediaDownloadWorker')",
        schema: %Schema{type: :string}
      ],
      state: [
        in: :query,
        description: "Filter by job state",
        schema: %Schema{
          type: :string,
          enum: ["available", "scheduled", "executing", "retryable", "completed", "discarded", "cancelled"]
        }
      ]
    ],
    responses: [
      ok: {"List of tasks", "application/json", Schemas.TasksListResponse}
    ]
  )

  def index(conn, params) do
    tasks =
      cond do
        source_id = params["source_id"] ->
          source = Repo.get!(Source, source_id)
          worker = params["worker"]
          states = parse_states(params["state"])
          Tasks.list_tasks_for(source, worker, states)

        media_item_id = params["media_item_id"] ->
          media_item = Repo.get!(MediaItem, media_item_id)
          worker = params["worker"]
          states = parse_states(params["state"])
          Tasks.list_tasks_for(media_item, worker, states)

        true ->
          # Use inner join to filter out orphaned tasks (tasks whose jobs have been pruned)
          query = from(t in Task, join: j in assoc(t, :job), preload: [job: j])

          query =
            if worker = params["worker"] do
              worker_finder = "%.#{worker}"

              from([t, j] in query,
                where: fragment("? LIKE ?", j.worker, ^worker_finder)
              )
            else
              query
            end

          query =
            if state = params["state"] do
              from([t, j] in query,
                where: j.state == ^to_string(state)
              )
            else
              query
            end

          Repo.all(query)
      end

    # For tasks from list_tasks_for, preload jobs; filter out any with nil jobs
    tasks_with_jobs =
      tasks
      |> Repo.preload(:job)
      |> Enum.filter(fn task -> task.job != nil end)

    serialized_tasks =
      Enum.map(tasks_with_jobs, fn task ->
        %{
          id: task.id,
          job_id: task.job_id,
          source_id: task.source_id,
          media_item_id: task.media_item_id,
          worker: task.job.worker,
          state: task.job.state,
          args: task.job.args,
          errors: task.job.errors,
          progress_percent: task.progress_percent,
          progress_status: task.progress_status,
          progress_downloaded_bytes: task.progress_downloaded_bytes,
          progress_total_bytes: task.progress_total_bytes,
          progress_eta_seconds: task.progress_eta_seconds,
          progress_speed_bytes_per_second: task.progress_speed_bytes_per_second,
          attempt: task.job.attempt,
          max_attempts: task.job.max_attempts,
          inserted_at: task.inserted_at,
          scheduled_at: task.job.scheduled_at,
          attempted_at: task.job.attempted_at,
          completed_at: task.job.completed_at
        }
      end)

    conn
    |> put_status(:ok)
    |> json(%{data: serialized_tasks})
  end

  operation(:show,
    operation_id: "Api.TaskController.show",
    summary: "Get task",
    description: "Returns details for a specific task",
    parameters: [
      id: [in: :path, description: "Task ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Task details", "application/json", Schemas.Task},
      not_found: {"Task not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    task = Tasks.get_task!(id) |> Repo.preload(:job)

    # Handle orphaned tasks (job was pruned by Oban)
    if task.job == nil do
      conn
      |> put_status(:not_found)
      |> json(%{error: "Task's job has been pruned"})
    else
      serialized_task = %{
        id: task.id,
        job_id: task.job_id,
        source_id: task.source_id,
        media_item_id: task.media_item_id,
        worker: task.job.worker,
        state: task.job.state,
        args: task.job.args,
        errors: task.job.errors,
        progress_percent: task.progress_percent,
        progress_status: task.progress_status,
        progress_downloaded_bytes: task.progress_downloaded_bytes,
        progress_total_bytes: task.progress_total_bytes,
        progress_eta_seconds: task.progress_eta_seconds,
        progress_speed_bytes_per_second: task.progress_speed_bytes_per_second,
        attempt: task.job.attempt,
        max_attempts: task.job.max_attempts,
        inserted_at: task.inserted_at,
        scheduled_at: task.job.scheduled_at,
        attempted_at: task.job.attempted_at,
        completed_at: task.job.completed_at
      }

      conn
      |> put_status(:ok)
      |> json(serialized_task)
    end
  end

  operation(:delete,
    operation_id: "Api.TaskController.delete",
    summary: "Cancel task",
    description: "Cancels and deletes a task",
    parameters: [
      id: [in: :path, description: "Task ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Task cancelled successfully", "application/json", Schemas.ActionResponse},
      not_found: {"Task not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def delete(conn, %{"id" => id}) do
    task = Tasks.get_task!(id)
    {:ok, _task} = Tasks.delete_task(task)

    conn
    |> put_status(:ok)
    |> json(%{message: "Task cancelled successfully"})
  end

  defp parse_states(nil), do: Oban.Job.states()

  defp parse_states(state) when is_binary(state) do
    [String.to_existing_atom(state)]
  end

  defp parse_states(states) when is_list(states) do
    Enum.map(states, &String.to_existing_atom/1)
  end
end
