defmodule PinchflatWeb.Sources.SourceController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use Pinchflat.Sources.SourcesQuery
  import Ecto.Query, warn: false

  alias OpenApiSpex.Schema
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Sources
  alias Pinchflat.Sources.CustomPoster
  alias Pinchflat.Reconciliation
  alias Pinchflat.Sources.Source
  alias Pinchflat.Sources.SourceImport
  alias Pinchflat.Sources.SourceActions
  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Settings.YtDlpConfigFile
  alias PinchflatWeb.Schemas
  alias PinchflatWeb.Sources.SourceHTML
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive
  alias PinchflatWeb.YtDlpOptionsHelpers

  # Set by the view toggle on the sources page (see index_table_live.html.heex).
  @source_view_cookie "pinchflat_sources_view"

  tags(["Sources"])

  operation(:index,
    operation_id: "Sources.SourceController.index",
    summary: "List sources",
    description: "Returns a list of all sources",
    responses: [
      ok: {"List of sources", "application/json", Schemas.SourcesListResponse}
    ]
  )

  def index(conn, params) do
    case get_format(conn) do
      "json" ->
        sources = Sources.list_sources() |> Sources.preload_api_assocs()
        conn |> put_status(:ok) |> json(%{data: sources})

      _ ->
        source_type = if params["type"] == "videos", do: "videos", else: "channels"
        # An explicit ?view= wins; otherwise reopen the view the browser last chose.
        initial_view_mode =
          source_view_mode(params["view"]) || source_view_mode(fetch_cookies(conn).req_cookies[@source_view_cookie])

        search_term = IndexTableLive.normalize_search_term(params["q"])

        conn
        |> PinchflatWeb.Layouts.put_toast_flash()
        |> render(:index,
          source_type: source_type,
          initial_view_mode: initial_view_mode,
          search_term: search_term
        )
    end
  end

  def import_new(conn, _params) do
    render(conn, :import_new, media_profiles: media_profiles(), preview: nil, error: nil)
  end

  def import_create(conn, %{"import" => %{"file" => %Plug.Upload{} = upload, "media_profile_id" => profile_id}}) do
    with {:ok, profile} <- available_import_profile(profile_id),
         {:ok, %{size: size}} when size <= 100_000 <- File.stat(upload.path),
         {:ok, contents} <- File.read(upload.path),
         {:ok, preview} <- SourceImport.parse(contents, upload.filename) do
      session = %{
        "urls" => preview.urls,
        "profile_id" => profile.id,
        "duplicates" => preview.duplicates,
        "titles" => preview.titles,
        "channel_ids" => preview.channel_ids,
        "row_errors" => preview.row_errors,
        "download_media" => preview.download_media
      }

      render(conn, :import_new, media_profiles: media_profiles(), preview: session, error: nil)
    else
      {:error, message} when is_binary(message) -> import_error(conn, message)
      _ -> import_error(conn, "Choose an available profile and a source file (100 KB maximum).")
    end
  end

  def import_create(conn, _params), do: import_error(conn, "Choose a media profile and a .txt or .csv source file.")

  defp import_error(conn, message) do
    render(conn, :import_new, media_profiles: media_profiles(), preview: nil, error: message)
  end

  defp available_import_profile(id) when is_binary(id) do
    if Regex.match?(~r/\A[1-9][0-9]{0,17}\z/, id) do
      query = from p in MediaProfile, where: p.id == ^String.to_integer(id) and is_nil(p.marked_for_deletion_at)

      case Repo.one(query) do
        nil -> {:error, "The selected media profile is no longer available."}
        profile -> {:ok, profile}
      end
    else
      {:error, "Choose an available media profile."}
    end
  end

  defp available_import_profile(_id), do: {:error, "Choose an available media profile."}

  def new(conn, params) do
    profiles = media_profiles()

    default_profile_id =
      Profiles.default_media_profile_id(profiles) || if(profile = List.first(profiles), do: profile.id, else: nil)

    default_source = %Source{cookie_behaviour: default_cookie_behaviour(), media_profile_id: default_profile_id}

    # This lets me preload the settings from another source for more efficient creation
    %Source{} =
      cs_struct =
      case to_string(params["template_id"]) do
        # A fresh source pre-selects the configured default cookie behaviour;
        # cloning from a template keeps that template's cookie behaviour instead
        "" -> default_source
        template_id -> Repo.get(Source, template_id) || default_source
      end

    options = source_options_new(profiles, cs_struct.media_profile_id)

    prefill_attrs =
      params
      |> prefill_source_attrs()
      |> Sources.enrich_new_source_attrs_from_url(cookie_behaviour: default_cookie_behaviour())

    render(
      conn,
      :new,
      Keyword.merge(
        [
          media_profiles: profiles,
          available_folders: saved_source_folders(),
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
            |> Sources.change_source(prefill_attrs)
            |> maybe_default_cookie_behaviour()
        ],
        cookie_file_assigns() ++ Map.to_list(options)
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

  def create(conn, %{"source" => source_params} = params) do
    format = get_format(conn)
    source_params = normalize_sponsorblock_source_params(source_params, format)
    params = Map.put(params, "source", source_params)
    delay_automatic_download = truthy_param?(Map.get(source_params, "delay_automatic_download", false))

    opts =
      if format == "json" do
        [delay_automatic_download: delay_automatic_download]
      else
        Keyword.merge(
          [delay_automatic_download: delay_automatic_download],
          YtDlpOptionsHelpers.options_opts(params, :missing)
        )
      end

    case Sources.create_source(source_params, opts) do
      {:ok, source} ->
        respond_source_created(conn, source, [])

      {:ok, source, warnings} ->
        respond_source_created(conn, source, warnings)

      {:error, %Ecto.Changeset{} = changeset} ->
        source_create_error(conn, changeset, params, nil)

      {:error, %Ecto.Changeset{} = changeset, reason} ->
        source_create_error(conn, changeset, params, reason)
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
    active_tab = tab_param(conn.params, allowed_tabs_for(source), "videos")

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
        indexing_failed? = Sources.indexing_failing?(source)

        pending_tasks =
          source
          |> Pinchflat.Tasks.list_tasks_for(nil, [:available, :scheduled, :executing, :retryable])
          |> Repo.preload(:job)

        render(conn, :show,
          source: source,
          active_tab: active_tab,
          tab_href: fn tab -> ~p"/sources/#{source}?#{[tab: tab]}" end,
          selection_media_items: selection_media_items,
          media_statistics: Media.source_media_statistics(source),
          blocking_conditions: Sources.blocking_conditions(source, indexing_failed?: indexing_failed?),
          source_status: Sources.status(source, indexing_failed?: indexing_failed?),
          downloading: MapSet.member?(Sources.downloading_source_ids([source.id]), source.id),
          pending_count: Media.count_pending_media_items_for(source),
          pending_tasks: pending_tasks
        )
    end
  end

  def edit(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    changeset = Sources.change_source(source)
    profiles = media_profiles()
    options = source_options_edit(source, profiles)

    render(
      conn,
      :edit,
      Keyword.merge(
        [
          source: source,
          changeset: changeset,
          media_profiles: profiles,
          available_folders: saved_source_folders(),
          cutoff_downloaded_items: cutoff_downloaded_items(source),
          current_path: ~p"/sources/#{source}/edit"
        ],
        cookie_file_assigns() ++ Map.to_list(options)
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

  def update(conn, %{"id" => id, "source" => source_params} = params) do
    source = Sources.get_source!(id)

    if should_confirm_directory_move?(conn, params, source, source_params) do
      render_directory_move_confirmation(conn, source, source_params)
    else
      confirm_keep_newest_or_update(conn, source, source_params, params)
    end
  end

  defp confirm_keep_newest_or_update(conn, source, source_params, params) do
    case keep_newest_confirmation(conn, params, source, source_params) do
      %{removable_count: count} -> render_keep_newest_confirmation(conn, source, source_params, count)
      nil -> do_update(conn, source, source_params)
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

  @title_filter_test_limit 50

  @doc """
  Tests a title filter regex against pasted sample titles and, for a saved
  source, its most recent indexed titles.

  Returns JSON %{samples: [...], indexed: [...]} or a 422 with %{error: binary()}
  """
  def test_title_filter(conn, params) do
    regex = params |> Map.get("regex", "") |> to_string() |> String.trim()

    samples =
      params
      |> Map.get("titles", "")
      |> to_string()
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(@title_filter_test_limit)

    indexed =
      case Integer.parse(to_string(params["source_id"])) do
        {source_id, ""} -> Sources.recent_media_titles(source_id, @title_filter_test_limit)
        _ -> []
      end

    with false <- regex == "",
         {:ok, sample_results} <- Sources.test_title_filter(regex, samples),
         {:ok, indexed_results} <- Sources.test_title_filter(regex, indexed) do
      json(conn, %{samples: sample_results, indexed: indexed_results})
    else
      true ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Enter a regex to test."})

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "The database could not use this regex: #{message}"})
    end
  end

  def list_title_filters(conn, _params) do
    json(conn, %{filters: saved_title_filters_json()})
  end

  def create_title_filter(conn, params) do
    params
    |> Map.take(["name", "regex"])
    |> Sources.create_saved_title_filter()
    |> saved_title_filter_response(conn)
  end

  def update_title_filter(conn, %{"id" => id} = params) do
    case Integer.parse(id) do
      {id, ""} ->
        id
        |> Sources.update_saved_title_filter(Map.take(params, ["regex"]))
        |> saved_title_filter_response(conn)

      _ ->
        saved_title_filter_response({:error, :not_found}, conn)
    end
  end

  def delete_title_filter(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, _saved_title_filter} <- Sources.delete_saved_title_filter(id) do
      json(conn, %{filters: saved_title_filters_json()})
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "That stored filter no longer exists.", filters: saved_title_filters_json()})
    end
  end

  def upload_poster(conn, %{"source_id" => id, "poster" => %{"file" => %Plug.Upload{} = upload}}) do
    source = Sources.get_source!(id)
    finish_poster_action(conn, source, CustomPoster.set_from_upload(source, upload))
  end

  def upload_poster(conn, %{"source_id" => id}) do
    source = Sources.get_source!(id)

    conn
    |> put_flash(:error, "Please choose a valid poster file.")
    |> redirect(to: ~p"/sources/#{source}/edit")
  end

  def set_poster_url(conn, %{"source_id" => id, "poster" => %{"url" => url}}) do
    source = Sources.get_source!(id)
    finish_poster_action(conn, source, CustomPoster.set_from_url(source, url))
  end

  def set_poster_url(conn, %{"source_id" => id}) do
    source = Sources.get_source!(id)

    conn
    |> put_flash(:error, "Please enter a public HTTP(S) poster URL.")
    |> redirect(to: ~p"/sources/#{source}/edit")
  end

  def remove_poster(conn, %{"source_id" => id}) do
    source = Sources.get_source!(id)
    finish_poster_action(conn, source, CustomPoster.remove(source), :removed)
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
      not_found: {"Source not found", "application/json", Schemas.NotFoundResponse},
      conflict: {"Watch protection blocks deletion", "application/json", Schemas.ActionErrorResponse}
    ]
  )

  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    source = Sources.get_source!(id)

    if Pinchflat.MediaWatch.deletion_blocked?(source) do
      message =
        "End watch protection for this source's watched videos before deleting the source. Download any saved originals you want to keep first."

      case get_format(conn) do
        "json" -> conn |> put_status(:conflict) |> json(%{error: message})
        _ -> conn |> put_flash(:error, message) |> redirect(to: ~p"/sources/#{source}")
      end
    else
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
          |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
      end
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

  def pause_selected(conn, params) do
    case Sources.pause_selected_sources(params["source_ids"]) do
      {:ok, sources} ->
        noun = if length(sources) == 1, do: "source", else: "sources"

        conn
        |> put_flash(:info, "Downloads paused for #{length(sources)} #{noun}.")
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Could not pause the selection. Refresh and select up to #{Sources.selection_limit()} available sources."
        )
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
    end
  end

  def resume_selected(conn, params) do
    case Sources.resume_selected_sources(params["source_ids"]) do
      {:ok, sources} ->
        noun = if length(sources) == 1, do: "source", else: "sources"

        conn
        |> put_flash(:info, "Downloads resumed for #{length(sources)} #{noun}.")
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Could not resume the selection. Refresh and select up to #{Sources.selection_limit()} available sources."
        )
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
    end
  end

  def delete_selected(conn, params) do
    delete_files = params["delete_files"] == "true"

    case Sources.delete_selected_sources(params["source_ids"], delete_files: delete_files) do
      {:ok, sources} ->
        noun = if length(sources) == 1, do: "source", else: "sources"

        message =
          if delete_files,
            do: "Deleting #{length(sources)} #{noun} and their downloaded files. This may take a while.",
            else: "Deleting #{length(sources)} #{noun}. Downloaded files are kept. This may take a while."

        conn
        |> put_flash(:info, message)
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))

      {:error, :watch_protected} ->
        conn
        |> put_flash(
          :error,
          "Nothing was deleted. End watch protection for the selected sources' watched videos first."
        )
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Could not delete the selection. Refresh and select up to #{Sources.selection_limit()} available sources."
        )
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
    end
  end

  def assign_profile_selected(conn, params) do
    profile_id = params["media_profile_id"]

    if is_nil(profile_id) or profile_id == "" do
      conn
      |> put_flash(:error, "Please select a media profile.")
      |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
    else
      case Sources.assign_selected_sources_profile(params["source_ids"], profile_id) do
        {:ok, sources} ->
          noun = if length(sources) == 1, do: "source", else: "sources"

          conn
          |> put_flash(:info, "Media profile updated for #{length(sources)} #{noun}.")
          |> redirect(to: SourceHTML.source_list_path(params["return_to"]))

        {:error, _reason} ->
          conn
          |> put_flash(
            :error,
            "Could not update media profile for the selection. " <>
              "Select a media profile and up to #{Sources.selection_limit()} available sources."
          )
          |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
      end
    end
  end

  def pause_all(conn, %{"source_id" => id} = params) do
    source = Sources.get_source!(id)

    if active_downloads_for_source?(source) || queued_downloads_for_source?(source) do
      {:ok, source} = Sources.update_source(source, %{download_media: false})
      DownloadingHelpers.dequeue_pending_download_tasks(source, include_executing: true)

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
      DownloadingHelpers.dequeue_pending_download_tasks(source, include_executing: true)

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

  def force_download_pending(conn, %{"source_id" => id} = params) do
    wrap_forced_action(
      conn,
      params,
      id,
      "Forcing download of pending media items.",
      &SourceActions.kickoff(:download_pending, &1)
    )
  end

  def force_redownload(conn, %{"source_id" => id} = params) do
    wrap_forced_action(
      conn,
      params,
      id,
      "Forcing re-download of downloaded media items.",
      &SourceActions.kickoff(:redownload_existing, &1)
    )
  end

  def force_index(conn, %{"source_id" => id} = params) do
    wrap_forced_action(
      conn,
      params,
      id,
      "Index enqueued.",
      &SourceActions.kickoff(:force_index, &1)
    )
  end

  def force_metadata_refresh(conn, %{"source_id" => id} = params) do
    wrap_forced_action(
      conn,
      params,
      id,
      "Metadata refresh enqueued.",
      &SourceActions.kickoff(:refresh_metadata, &1)
    )
  end

  def sync_files_on_disk(conn, %{"source_id" => id} = params) do
    wrap_forced_action(
      conn,
      params,
      id,
      "File sync enqueued.",
      &SourceActions.kickoff(:sync_files, &1)
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

  defp do_update(conn, source, source_params) do
    format = get_format(conn)
    source_params = normalize_sponsorblock_source_params(source_params, format)

    opts =
      if format == "json" do
        []
      else
        YtDlpOptionsHelpers.options_opts(conn.params, :any)
      end

    case Sources.update_source(source, source_params, opts) do
      {:ok, source} ->
        respond_source_updated(conn, source, [])

      {:ok, source, warnings} ->
        respond_source_updated(conn, source, warnings)

      {:error, %Ecto.Changeset{} = changeset} ->
        source_update_error(conn, source, changeset, nil)

      {:error, %Ecto.Changeset{} = changeset, reason} ->
        source_update_error(conn, source, changeset, reason)
    end
  end

  defp respond_source_created(conn, source, warnings) do
    case get_format(conn) do
      "json" ->
        source = Sources.preload_api_assocs(source)
        conn |> put_status(:created) |> json(source)

      _ ->
        conn
        |> source_flash(warnings, "Source created successfully.")
        |> redirect(to: source_created_path(source))
    end
  end

  defp respond_source_updated(conn, source, warnings) do
    Reconciliation.mark_ready_plans_stale()

    case get_format(conn) do
      "json" ->
        source = Sources.preload_api_assocs(source)
        conn |> put_status(:ok) |> json(source)

      _ ->
        conn
        |> source_flash(warnings, "Source updated successfully.")
        |> redirect(to: ~p"/sources/#{source}?#{[tab: "source"]}")
    end
  end

  defp source_created_path(source) do
    cond do
      Settings.get!(:onboarding) ->
        ~p"/?onboarding=1"

      source.collection_type == :playlist && source.selection_mode == :manual ->
        ~p"/sources/#{source}?#{[tab: "selection"]}"

      true ->
        ~p"/sources/#{source}"
    end
  end

  defp source_flash(conn, [], message), do: put_flash(conn, :info, message)

  defp source_flash(conn, _warnings, _message) do
    put_flash(
      conn,
      :error,
      "Source saved with custom yt-dlp options, but indexing could not be queued. Use Check for new videos to retry."
    )
  end

  defp source_create_error(conn, changeset, params, reason) do
    case get_format(conn) do
      "json" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset_errors(changeset)})

      _ ->
        profiles = media_profiles()
        source_params = Map.get(params, "source", %{})
        profile_id = integer_id(source_params["media_profile_id"])
        options = submitted_source_options(params, profiles, profile_id, nil, reason, :missing)

        render(
          conn,
          :new,
          Keyword.merge(
            [
              changeset: changeset,
              media_profiles: profiles,
              available_folders: saved_source_folders(),
              current_path: ~p"/sources/new",
              layout: get_onboarding_layout(),
              new_source: true,
              show_delay_automatic_download: true
            ],
            cookie_file_assigns() ++ Map.to_list(options)
          )
        )
    end
  end

  defp source_update_error(conn, source, changeset, reason) do
    case get_format(conn) do
      "json" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset_errors(changeset)})

      _ ->
        profiles = media_profiles()
        options = submitted_source_options(conn.params, profiles, source.media_profile_id, source.id, reason, :any)

        render(
          conn,
          :edit,
          Keyword.merge(
            [
              source: source,
              changeset: %{changeset | action: :update},
              media_profiles: profiles,
              available_folders: saved_source_folders(),
              cutoff_downloaded_items: cutoff_downloaded_items(source),
              current_path: ~p"/sources/#{source}/edit"
            ],
            cookie_file_assigns() ++ Map.to_list(options)
          )
        )
    end
  end

  defp finish_poster_action(conn, source, {:ok, _updated_source}, :removed) do
    conn
    |> put_flash(:info, "Custom poster removed. The fetched poster will be used again.")
    |> redirect(to: ~p"/sources/#{source}/edit")
  end

  defp finish_poster_action(conn, source, {:ok, _updated_source}) do
    conn
    |> put_flash(:info, "Custom poster saved.")
    |> redirect(to: ~p"/sources/#{source}/edit")
  end

  defp finish_poster_action(conn, source, {:error, reason}) do
    conn
    |> put_flash(:error, poster_error_message(reason))
    |> redirect(to: ~p"/sources/#{source}/edit")
  end

  defp poster_error_message(:invalid_upload), do: "Please choose a valid poster file."
  defp poster_error_message(:too_large), do: "The poster must be 10 MB or smaller."
  defp poster_error_message(:invalid_image), do: "The poster must be a valid JPEG, PNG, or WebP image."
  defp poster_error_message(:invalid_response), do: "The poster URL did not return a valid JPEG, PNG, or WebP image."
  defp poster_error_message(:invalid_url), do: "Enter a public HTTP(S) poster URL."
  defp poster_error_message(:unsafe_url), do: "That poster URL is not allowed."
  defp poster_error_message(:unresolvable_host), do: "That poster URL host could not be resolved."
  defp poster_error_message(:image_validator_unavailable), do: "Poster validation is temporarily unavailable."
  defp poster_error_message(_reason), do: "The custom poster could not be saved."

  defp should_confirm_directory_move?(conn, params, _source, _source_params) do
    get_format(conn) != "json" && !truthy_param?(Map.get(params, "confirm_directory_move"))
  end

  # Returns `%{removable_count: integer()}` when an HTML update would cull
  # downloaded files at the next cleanup, otherwise nil. JSON requests skip the
  # confirmation and update directly.
  defp keep_newest_confirmation(conn, params, source, source_params) do
    with true <- get_format(conn) != "json",
         false <- truthy_param?(Map.get(params, "confirm_keep_newest")),
         {:ok, new_count} <- positive_integer(source_params["keep_newest_count"]),
         true <- is_nil(source.keep_newest_count) or new_count < source.keep_newest_count,
         count when count > 0 <- Sources.count_removable_media_for_keep_newest(source, new_count) do
      %{removable_count: count}
    else
      _ -> nil
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count > 0 -> {:ok, count}
      _ -> :error
    end
  end

  defp positive_integer(_value), do: :error

  defp render_keep_newest_confirmation(conn, source, source_params, removable_count) do
    render(conn, :confirm_keep_newest,
      source: source,
      source_params: source_params,
      removable_count: removable_count,
      new_count: source_params["keep_newest_count"],
      # Only what was submitted: an absent payload must stay absent, or saving would clear the config file.
      extra_params: Map.take(conn.params, ["yt_dlp_options", "yt_dlp_options_version"])
    )
  end

  defp render_directory_move_confirmation(conn, source, source_params) do
    case Sources.preview_source_directory_move(source, source_params) do
      {:ok, nil} ->
        confirm_keep_newest_or_update(conn, source, source_params, conn.params)

      {:ok, directory_move_plan} ->
        profiles = media_profiles()
        options = submitted_source_options(conn.params, profiles, source.media_profile_id, source.id, nil, :any)

        render(
          conn,
          :confirm_directory_move,
          Keyword.merge(
            [
              source: source,
              source_params: source_params,
              directory_move_plan: directory_move_plan
            ],
            Map.to_list(options)
          )
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        source_update_error(conn, source, %{changeset | action: :update}, nil)
    end
  end

  # From the sources list (a `return_to`), the message names the source and the list is reloaded.
  defp wrap_forced_action(conn, params, source_id, message, fun) do
    source = Sources.get_source!(source_id)
    feedback = PinchflatWeb.Helpers.JobActionHelpers.feedback(fun.(source), message)

    case params["return_to"] do
      return_to when is_binary(return_to) and return_to != "" ->
        conn
        |> put_flash(feedback.type, "#{source.custom_name}: #{feedback.message}")
        |> redirect(to: SourceHTML.source_list_path(return_to))

      _ ->
        conn
        |> put_flash(feedback.type, feedback.message)
        |> redirect(to: ~p"/sources/#{source}")
    end
  end

  defp redirect_target_for(params, source, fallback) do
    case Map.get(params, "return_to") do
      value when is_binary(value) and value != "" -> value
      _ -> fallback || ~p"/sources/#{source}"
    end
  end

  defp source_options_new(profiles, default_profile_id) do
    Map.merge(YtDlpOptionsHelpers.base_assigns(), %{
      yt_dlp_options_inherited: source_inherited(default_profile_id, nil),
      yt_dlp_options_profile_presence: profile_presence(profiles)
    })
  end

  defp source_options_edit(source, profiles) do
    inherited = source_inherited(source.media_profile_id, source.id)
    YtDlpOptionsHelpers.load_assigns(:source, source.id, inherited, profile_presence(profiles))
  end

  defp source_inherited(profile_id, source_id) do
    %{
      base: YtDlpConfigFile.present?(),
      profile: is_integer(profile_id) and YtDlpConfigFile.present_scope?(:profile, profile_id),
      source: is_integer(source_id) and YtDlpConfigFile.present_scope?(:source, source_id)
    }
  end

  defp profile_presence(profiles) do
    Enum.into(profiles, %{}, fn profile ->
      {profile.id, YtDlpConfigFile.present_scope?(:profile, profile.id)}
    end)
  end

  defp submitted_source_options(params, profiles, profile_id, source_id, reason, default_version) do
    error = if reason, do: YtDlpOptionsHelpers.message(reason)

    options =
      YtDlpOptionsHelpers.submitted_assigns(
        params,
        source_inherited(profile_id, source_id),
        profile_presence(profiles),
        error,
        default_version
      )

    if reason == :stale_conflict and is_integer(source_id) do
      case YtDlpConfigFile.read_scope(:source, source_id) do
        {:ok, %{version: version}} -> %{options | yt_dlp_options_version: version}
        _ -> options
      end
    else
      options
    end
  end

  defp integer_id(value) when is_integer(value), do: value

  defp integer_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp integer_id(_value), do: nil

  defp media_profiles do
    MediaProfile
    |> where([mp], is_nil(mp.marked_for_deletion_at))
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp default_cookie_behaviour do
    String.to_existing_atom(Settings.get!(:default_cookie_behaviour))
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

  defp prefill_source_attrs(params) do
    %{}
    |> maybe_put_prefill("original_url", params["original_url"])
    |> maybe_put_prefill("custom_name", params["custom_name"])
    |> maybe_put_source_type_prefill(params["source_type"])
    |> maybe_put_prefill_boolean("custom_name_locked", params["custom_name_locked"])
    |> maybe_put_prefill_boolean("download_members_only_media", params["download_members_only_media"])
  end

  defp maybe_put_prefill(attrs, key, value) when is_binary(value) and value != "" do
    Map.put(attrs, key, value)
  end

  defp maybe_put_prefill(attrs, _key, _value), do: attrs

  defp maybe_put_prefill_boolean(attrs, _key, nil), do: attrs
  defp maybe_put_prefill_boolean(attrs, _key, ""), do: attrs

  defp maybe_put_prefill_boolean(attrs, key, value) when is_binary(value) do
    case parse_prefill_boolean(value) do
      :skip -> attrs
      bool -> Map.put(attrs, key, bool)
    end
  end

  defp maybe_put_prefill_boolean(attrs, key, value) when is_boolean(value), do: Map.put(attrs, key, value)
  defp maybe_put_prefill_boolean(attrs, _key, _value), do: attrs

  defp parse_prefill_boolean(value) do
    case String.downcase(String.trim(value)) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> :skip
    end
  end

  defp maybe_put_source_type_prefill(attrs, source_type) when is_binary(source_type) do
    case Enum.find_value(Source.source_type_options(), fn {_label, option} ->
           if Atom.to_string(option) == source_type, do: option
         end) do
      nil -> attrs
      option -> Map.put(attrs, "source_type", option)
    end
  end

  defp maybe_put_source_type_prefill(attrs, _source_type), do: attrs

  defp source_view_mode("grid"), do: :grid
  defp source_view_mode("table"), do: :table
  defp source_view_mode(_view), do: nil

  defp tab_param(params, allowed_tabs, default_tab) do
    tab =
      case params["tab"] do
        "downloaded" -> "videos"
        other -> other
      end

    if tab in allowed_tabs do
      tab
    else
      default_tab
    end
  end

  defp truthy_param?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy_param?(_value), do: false

  # The HTML form posts an explicit mode alongside each checkbox group, because a
  # browser can only submit a list (an unchecked group submits just the hidden
  # input's empty string, which Ecto casts to []). JSON clients send the list
  # directly, so this only rewrites the three HTML states.
  defp normalize_sponsorblock_source_params(source_params, "json"), do: source_params

  defp normalize_sponsorblock_source_params(source_params, _format) when is_map(source_params) do
    Enum.reduce([:mark, :remove], source_params, fn action, params ->
      field = "sponsorblock_#{action}_categories"
      mode_key = "sponsorblock_#{action}_mode"

      case Map.fetch(params, mode_key) do
        :error ->
          params

        {:ok, mode} ->
          params
          |> Map.delete(mode_key)
          |> apply_sponsorblock_mode(field, mode)
      end
    end)
  end

  defp normalize_sponsorblock_source_params(source_params, _format), do: source_params

  defp apply_sponsorblock_mode(params, field, "inherit"), do: Map.put(params, field, nil)
  defp apply_sponsorblock_mode(params, field, "disable"), do: Map.put(params, field, [])
  defp apply_sponsorblock_mode(params, _field, _mode), do: params

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
    ~w(source videos pending failed selection active-tasks job-queue other podcast)
  end

  defp allowed_tabs_for(_source) do
    ~w(source videos pending failed active-tasks job-queue other podcast)
  end

  # Lightweight publication dates for the cutoff deletion preview. Only
  # downloaded, unprotected items can be removed by cutoff cleanup, so the form
  # only needs those dates.
  defp cutoff_downloaded_items(%Source{id: source_id}) do
    from(m in MediaItem,
      where: m.source_id == ^source_id and not is_nil(m.media_filepath) and not is_nil(m.uploaded_at),
      select: %{uploaded_at: m.uploaded_at, prevent_culling: m.prevent_culling}
    )
    |> Repo.all()
    |> Enum.map(fn item ->
      %{d: item.uploaded_at |> DateTime.to_date() |> Date.to_iso8601(), p: item.prevent_culling == true}
    end)
  end

  defp saved_source_folders do
    Source
    |> where([source], not is_nil(source.download_subdirectory) and source.download_subdirectory != "")
    |> select([source], source.download_subdirectory)
    |> distinct(true)
    |> order_by([source], asc: source.download_subdirectory)
    |> limit(200)
    |> Repo.all()
  end

  defp saved_title_filter_response({:ok, saved_title_filter}, conn) do
    json(conn, %{filter: saved_title_filter_json(saved_title_filter), filters: saved_title_filters_json()})
  end

  defp saved_title_filter_response({:error, :not_found}, conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "That stored filter no longer exists.", filters: saved_title_filters_json()})
  end

  defp saved_title_filter_response({:error, changeset}, conn) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: saved_title_filter_error(changeset)})
  end

  defp saved_title_filters_json do
    Enum.map(Sources.list_saved_title_filters(), &saved_title_filter_json/1)
  end

  defp saved_title_filter_json(saved_title_filter) do
    Map.take(saved_title_filter, [:id, :name, :regex])
  end

  defp saved_title_filter_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&PinchflatWeb.CoreComponents.translate_error/1)
    |> Enum.map_join(" ", fn {field, [message | _]} -> "#{Phoenix.Naming.humanize(field)} #{message}." end)
  end
end
