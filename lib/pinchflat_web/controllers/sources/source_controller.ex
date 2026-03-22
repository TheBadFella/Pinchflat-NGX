defmodule PinchflatWeb.Sources.SourceController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use Pinchflat.Sources.SourcesQuery

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias PinchflatWeb.Schemas

  tags(["Sources"])

  operation(:index,
    operation_id: "Sources.SourceController.index",
    summary: "List sources",
    description: "Returns a list of all sources",
    responses: [
      ok: {"List of sources", "application/json", Schemas.SourcesListResponse}
    ]
  )

  def index(conn, _params) do
    sources = Sources.list_sources() |> Repo.preload(:media_profile)

    case get_format(conn) do
      "json" ->
        conn |> put_status(:ok) |> json(%{data: sources})

      _ ->
        render(conn, :index)
    end
  end

  def new(conn, params) do
    # This lets me preload the settings from another source for more efficient creation
    cs_struct =
      case to_string(params["template_id"]) do
        "" -> %Source{}
        template_id -> Repo.get(Source, template_id) || %Source{}
      end

    render(conn, :new,
      Keyword.merge(
        [
          media_profiles: media_profiles(),
          current_path: ~p"/sources/new",
          layout: get_onboarding_layout(),
          # Most of these don't actually _need_ to be nullified at this point,
          # but if I don't do it now I know it'll bite me
          changeset:
            %Source{
              cs_struct
              | id: nil,
                uuid: nil,
                custom_name: nil,
                description: nil,
                collection_name: nil,
                collection_id: nil,
                collection_type: nil,
                original_url: nil,
                marked_for_deletion_at: nil
            }
            |> Sources.change_source()
            |> maybe_default_cookie_behaviour()
        ],
        cookie_file_assigns()
      )
    )
  end

  operation(:create,
    operation_id: "Sources.SourceController.create",
    summary: "Create source",
    description: "Creates a new source from a YouTube channel, playlist, or single video URL",
    request_body: {"Source creation parameters", "application/json", Schemas.CreateSourceRequest},
    responses: [
      created: {"Source created successfully", "application/json", Schemas.Source},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ValidationErrorResponse}
    ]
  )

  def create(conn, %{"source" => source_params}) do
    case Sources.create_source(source_params) do
      {:ok, source} ->
        case get_format(conn) do
          "json" ->
            source = Repo.preload(source, :media_profile)
            conn |> put_status(:created) |> json(source)

          _ ->
            redirect_location =
              if Settings.get!(:onboarding), do: ~p"/?onboarding=1", else: ~p"/sources/#{source}"

            conn
            |> put_flash(:info, "Source created successfully.")
            |> redirect(to: redirect_location)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        case get_format(conn) do
          "json" ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_changeset_errors(changeset)})

          _ ->
            render(conn, :new,
              Keyword.merge(
                [
                  changeset: changeset,
                  media_profiles: media_profiles(),
                  current_path: ~p"/sources/new",
                  layout: get_onboarding_layout()
                ],
                cookie_file_assigns()
              )
            )
        end
    end
  end

  operation(:show,
    operation_id: "Sources.SourceController.show",
    summary: "Get source",
    description: "Returns details for a specific source",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      ok: {"Source details", "application/json", Schemas.Source},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    source = Repo.preload(Sources.get_source!(id), :media_profile)

    case get_format(conn) do
      "json" ->
        conn |> put_status(:ok) |> json(source)

      _ ->
        render(conn, :show, source: source)
    end
  end

  def edit(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    changeset = Sources.change_source(source)

    render(conn, :edit,
      Keyword.merge(
        [
          source: source,
          changeset: changeset,
          media_profiles: media_profiles(),
          current_path: ~p"/sources/#{source}/edit"
        ],
        cookie_file_assigns()
      )
    )
  end

  operation(:update,
    operation_id: "Sources.SourceController.update",
    summary: "Update source",
    description: "Updates an existing source",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    request_body: {"Source update parameters", "application/json", Schemas.UpdateSourceRequest},
    responses: [
      ok: {"Source updated successfully", "application/json", Schemas.Source},
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ValidationErrorResponse}
    ]
  )

  def update(conn, %{"id" => id, "source" => source_params}) do
    source = Sources.get_source!(id)

    case Sources.update_source(source, source_params) do
      {:ok, source} ->
        case get_format(conn) do
          "json" ->
            source = Repo.preload(source, :media_profile)
            conn |> put_status(:ok) |> json(source)

          _ ->
            conn
            |> put_flash(:info, "Source updated successfully.")
            |> redirect(to: ~p"/sources/#{source}")
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        case get_format(conn) do
          "json" ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_changeset_errors(changeset)})

          _ ->
            render(conn, :edit,
              Keyword.merge(
                [
                  source: source,
                  changeset: changeset,
                  media_profiles: media_profiles(),
                  current_path: ~p"/sources/#{source}/edit"
                ],
                cookie_file_assigns()
              )
            )
        end
    end
  end

  def upload_cookies(conn, %{"cookies" => %{"file" => %Plug.Upload{} = upload}, "return_to" => return_to}) do
    case Sources.save_uploaded_cookie_file(upload) do
      :ok ->
        conn
        |> put_flash(:info, "Cookie file uploaded successfully.")
        |> redirect(to: return_to)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Cookie file upload failed.")
        |> redirect(to: return_to)
    end
  end

  def upload_cookies(conn, %{"return_to" => return_to}) do
    conn
    |> put_flash(:error, "Please choose a cookie file to upload.")
    |> redirect(to: return_to)
  end

  def save_cookies(conn, %{"cookies" => %{"contents" => contents}, "return_to" => return_to}) do
    case Sources.write_cookie_file(contents) do
      :ok ->
        conn
        |> put_flash(:info, "Cookie file saved successfully.")
        |> redirect(to: return_to)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Cookie file save failed.")
        |> redirect(to: return_to)
    end
  end

  operation(:delete,
    operation_id: "Sources.SourceController.delete",
    summary: "Delete source",
    description: "Deletes a source and optionally its associated media files",
    parameters: [
      id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true],
      delete_files: [
        in: :query,
        description: "Also delete associated media files from disk",
        schema: %Schema{type: :boolean, default: false}
      ]
    ],
    responses: [
      ok: {
        "Source deletion started",
        "application/json",
        %Schema{
          type: :object,
          properties: %{message: %Schema{type: :string}}
        }
      },
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse}
    ]
  )

  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    source = Sources.get_source!(id)

    {:ok, source} = Sources.update_source(source, %{marked_for_deletion_at: DateTime.utc_now()})
    SourceDeletionWorker.kickoff(source, %{delete_files: delete_files})

    case get_format(conn) do
      "json" ->
        conn
        |> put_status(:ok)
        |> json(%{message: "Source deletion started. This may take a while to complete."})

      _ ->
        conn
        |> put_flash(:info, "Source deletion started. This may take a while to complete.")
        |> redirect(to: ~p"/sources")
    end
  end

  def force_download_pending(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing download of pending media items.",
      &DownloadingHelpers.enqueue_pending_download_tasks/1
    )
  end

  def force_redownload(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing re-download of downloaded media items.",
      &DownloadingHelpers.kickoff_redownload_for_existing_media/1
    )
  end

  def force_index(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Index enqueued.",
      &SlowIndexingHelpers.kickoff_indexing_task(&1, %{force: true})
    )
  end

  def force_metadata_refresh(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Metadata refresh enqueued.",
      &SourceMetadataStorageWorker.kickoff_with_task/1
    )
  end

  def sync_files_on_disk(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "File sync enqueued.",
      &FileSyncingWorker.kickoff_with_task/1
    )
  end

  defp wrap_forced_action(conn, source_id, message, fun) do
    source = Sources.get_source!(source_id)
    fun.(source)

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/sources/#{source}")
  end

  defp media_profiles do
    MediaProfile
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp get_onboarding_layout do
    if Settings.get!(:onboarding) do
      {Layouts, :onboarding}
    else
      {Layouts, :app}
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp cookie_file_assigns do
    cookie_file_contents =
      case Sources.read_cookie_file() do
        {:ok, contents} -> contents
        {:error, _reason} -> nil
      end

    [
      cookie_file_path: Sources.cookie_file_path(),
      cookie_file_exists: Sources.cookie_file_exists?(),
      cookie_file_configured: Sources.cookie_file_configured?(),
      cookie_file_contents: cookie_file_contents
    ]
  end

  defp maybe_default_cookie_behaviour(%Ecto.Changeset{} = changeset) do
    current_value = Ecto.Changeset.get_field(changeset, :cookie_behaviour)

    if Sources.cookie_file_configured?() && current_value == :disabled do
      Ecto.Changeset.put_change(changeset, :cookie_behaviour, :all_operations)
    else
      changeset
    end
  end
end
