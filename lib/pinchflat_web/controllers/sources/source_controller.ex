defmodule PinchflatWeb.Sources.SourceController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use Pinchflat.Sources.SourcesQuery
  import Ecto.Query, warn: false

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task
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
    sources = Sources.list_sources() |> Sources.preload_api_assocs()

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

    render(
      conn,
      :new,
      Keyword.merge(
        [
          media_profiles: media_profiles(),
          available_folders: available_media_directories(),
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
    delay_automatic_download = truthy_param?(Map.get(source_params, "delay_automatic_download", false))

    case Sources.create_source(source_params, delay_automatic_download: delay_automatic_download) do
      {:ok, source} ->
        case get_format(conn) do
          "json" ->
            source = Sources.preload_api_assocs(source)
            conn |> put_status(:created) |> json(source)

          _ ->
            redirect_location =
              cond do
                Settings.get!(:onboarding) ->
                  ~p"/?onboarding=1"

                source.collection_type == :playlist && source.selection_mode == :manual ->
                  ~p"/sources/#{source}?#{[tab: "selection"]}"

                true ->
                  ~p"/sources/#{source}"
              end

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
            render(
              conn,
              :new,
              Keyword.merge(
                [
                  changeset: changeset,
                  media_profiles: media_profiles(),
                  available_folders: available_media_directories(),
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
    source = Sources.get_source!(id) |> Sources.preload_api_assocs()
    active_tab = tab_param(conn.params, allowed_tabs_for(source), "source")

    selection_media_items =
      if active_tab == "selection" do
        Media.list_media_items_for_selection(source)
      else
        []
      end

    case get_format(conn) do
      "json" ->
        conn |> put_status(:ok) |> json(source)

      _ ->
        render(conn, :show,
          source: source,
          active_tab: active_tab,
          tab_href: fn tab -> ~p"/sources/#{source}?#{[tab: tab]}" end,
          selection_media_items: selection_media_items
        )
    end
  end

  def edit(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    changeset = Sources.change_source(source)

    render(
      conn,
      :edit,
      Keyword.merge(
        [
          source: source,
          changeset: changeset,
          media_profiles: media_profiles(),
          available_folders: available_media_directories(),
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
            source = Sources.preload_api_assocs(source)
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
            render(
              conn,
              :edit,
              Keyword.merge(
                [
                  source: source,
                  changeset: changeset,
                  media_profiles: media_profiles(),
                  available_folders: available_media_directories(),
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

  def start_all(conn, %{"source_id" => id} = params) do
    source = Sources.get_source!(id)

    if startable_source?(source) do
      {:ok, source} = Sources.update_source(source, %{enabled: true, download_media: true})

      conn
      |> put_flash(:info, "Source started.")
      |> redirect(to: redirect_target_for(params, source, ~p"/sources"))
    else
      conn
      |> put_flash(:info, "Nothing to download for this source.")
      |> redirect(to: redirect_target_for(params, source, ~p"/sources"))
    end
  end

  def pause_all(conn, %{"source_id" => id} = params) do
    source = Sources.get_source!(id)

    if active_downloads_for_source?(source) || queued_downloads_for_source?(source) do
      {:ok, source} = Sources.update_source(source, %{download_media: false})

      conn
      |> put_flash(:info, "Source downloads paused.")
      |> redirect(to: redirect_target_for(params, source, ~p"/sources"))
    else
      conn
      |> put_flash(:info, "No active downloads to pause for this source.")
      |> redirect(to: redirect_target_for(params, source, ~p"/sources"))
    end
  end

  def stop_all(conn, %{"source_id" => id} = params) do
    source = Sources.get_source!(id)

    if stoppable_source?(source) do
      {:ok, source} = Sources.update_source(source, %{enabled: false, download_media: false})
      Tasks.delete_pending_tasks_for(source, "MediaDownloadWorker", include_executing: true)

      conn
      |> put_flash(:info, "Source stopped.")
      |> redirect(to: redirect_target_for(params, source, ~p"/sources"))
    else
      conn
      |> put_flash(:info, "Nothing to stop for this source.")
      |> redirect(to: redirect_target_for(params, source, ~p"/sources"))
    end
  end

  def restore_automatic_downloads(conn, %{"source_id" => id} = params) do
    source = Sources.get_source!(id)

    case Sources.restore_automatic_downloads(source) do
      {:ok, source} ->
        conn
        |> put_flash(:info, "Automatic downloads restored for this source.")
        |> redirect(to: redirect_target_for(params, source, ~p"/sources/#{source}"))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, inspect(changeset.errors))
        |> redirect(to: redirect_target_for(params, source, ~p"/sources/#{source}/edit"))
    end
  end

  def force_download_pending(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing download of pending media items.",
      &DownloadingHelpers.retry_pending_download_tasks/1
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

  operation(:apply_selection,
    operation_id: "Sources.SourceController.apply_selection",
    summary: "Apply playlist selection",
    description: "Applies manual playlist selection for a source and can optionally enqueue selected downloads",
    parameters: [
      source_id: [in: :path, description: "Source ID", schema: %Schema{type: :integer}, required: true]
    ],
    responses: [
      found: {
        "Selection applied and browser redirected back to the source selection tab",
        "text/html",
        %Schema{type: :string}
      }
    ]
  )

  def apply_selection(conn, %{"source_id" => id} = params) do
    source = Sources.get_source!(id)

    selected_media_ids =
      merge_selected_media_ids(
        source,
        Map.get(params, "selected_media_ids", []),
        Map.get(params, "selection_range", "")
      )

    enable_downloads = Map.get(params, "selection_action", "save") == "download"

    case Sources.apply_media_selection(source, selected_media_ids, enable_downloads: enable_downloads) do
      {:ok, source} ->
        flash_message =
          if enable_downloads do
            "Selection saved and selected downloads enqueued."
          else
            "Selection saved."
          end

        conn
        |> put_flash(:info, flash_message)
        |> redirect(to: ~p"/sources/#{source}?#{[tab: "selection"]}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, inspect(changeset.errors))
        |> redirect(to: ~p"/sources/#{source}?#{[tab: "selection"]}")
    end
  end

  defp wrap_forced_action(conn, source_id, message, fun) do
    source = Sources.get_source!(source_id)
    fun.(source)

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/sources/#{source}")
  end

  defp redirect_target_for(params, source, fallback) do
    case Map.get(params, "return_to") do
      value when is_binary(value) and value != "" -> value
      _ -> fallback || ~p"/sources/#{source}"
    end
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

  defp tab_param(params, allowed_tabs, default_tab) do
    tab = params["tab"]

    if tab in allowed_tabs do
      tab
    else
      default_tab
    end
  end

  defp truthy_param?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy_param?(_value), do: false

  defp startable_source?(source) do
    source
    |> Media.list_pending_media_items_for()
    |> Enum.any?()
  end

  defp stoppable_source?(source) do
    active_downloads_for_source?(source) || queued_downloads_for_source?(source)
  end

  defp active_downloads_for_source?(source) do
    count_download_tasks_for_source(source, ["executing"]) > 0
  end

  defp queued_downloads_for_source?(source) do
    count_download_tasks_for_source(source, ["available", "scheduled", "retryable"]) > 0
  end

  defp count_download_tasks_for_source(source, states) do
    from(t in Task,
      join: j in assoc(t, :job),
      join: mi in assoc(t, :media_item),
      where: mi.source_id == ^source.id,
      where: fragment("? LIKE ?", j.worker, ^"%.MediaDownloadWorker"),
      where: j.state in ^states,
      select: count(t.id)
    )
    |> Repo.one()
  end

  defp merge_selected_media_ids(source, selected_media_ids, selection_range) do
    range_selected_ids =
      source
      |> Media.list_media_items_for_selection()
      |> Enum.filter(&(&1.playlist_index in parse_selection_range(selection_range)))
      |> Enum.map(&Integer.to_string(&1.id))

    selected_media_ids
    |> List.wrap()
    |> Kernel.++(range_selected_ids)
    |> Enum.uniq()
  end

  defp parse_selection_range(selection_range) do
    selection_range
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.flat_map(&parse_selection_segment/1)
    |> Enum.uniq()
  end

  defp parse_selection_segment(segment) do
    segment = String.trim(segment)

    cond do
      segment == "" ->
        []

      String.contains?(segment, "-") ->
        case String.split(segment, "-", parts: 2) do
          [start_segment, end_segment] ->
            case {Integer.parse(String.trim(start_segment)), Integer.parse(String.trim(end_segment))} do
              {{start_index, ""}, {end_index, ""}} ->
                Range.new(min(start_index, end_index), max(start_index, end_index)) |> Enum.to_list()

              _ ->
                []
            end

          _ ->
            []
        end

      true ->
        case Integer.parse(segment) do
          {parsed_index, ""} -> [parsed_index]
          _ -> []
        end
    end
  end

  defp allowed_tabs_for(%Source{collection_type: :playlist, selection_mode: :manual}) do
    ~w(source pending selection active-tasks downloaded job-queue other)
  end

  defp allowed_tabs_for(_source) do
    ~w(source pending active-tasks downloaded job-queue other)
  end

  defp available_media_directories do
    base_dir = Application.get_env(:pinchflat, :media_directory)

    if File.dir?(base_dir) do
      list_media_directories(base_dir)
      |> Enum.sort()
    else
      []
    end
  end

  defp list_media_directories(base_dir, relative_dir \\ "") do
    current_dir =
      case relative_dir do
        "" -> base_dir
        _ -> Path.join(base_dir, relative_dir)
      end

    case File.ls(current_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          relative_path =
            case relative_dir do
              "" -> entry
              _ -> Path.join(relative_dir, entry)
            end

          absolute_path = Path.join(base_dir, relative_path)

          if File.dir?(absolute_path) do
            [relative_path | list_media_directories(base_dir, relative_path)]
          else
            []
          end
        end)

      {:error, _reason} ->
        []
    end
  end
end
