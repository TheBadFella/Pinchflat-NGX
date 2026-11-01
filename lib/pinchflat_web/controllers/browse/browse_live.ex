defmodule PinchflatWeb.Browse.BrowseLive do
  @moduledoc false
  use PinchflatWeb, :live_view
  require Logger

  alias Pinchflat.Profiles
  alias Pinchflat.YoutubeBrowser
  alias Pinchflat.YoutubeBrowser.Status
  alias Pinchflat.YoutubeBrowser.UrlParser

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("job:state")
      PinchflatWeb.Endpoint.subscribe("job:progress")
    end

    profiles = Profiles.list_media_profiles()
    selected_profile_id = default_profile_id(profiles)

    socket =
      socket
      |> assign(:page_title, "Browse YouTube")
      |> assign(:profiles, profiles)
      |> assign(:selected_profile_id, selected_profile_id)
      |> assign(:query, "")
      |> assign(:active_tab, :videos)
      |> assign(:search_tab, nil)
      |> assign(:search_generation, 0)
      |> assign(:results, [])
      |> assign(:loading?, false)
      |> assign(:busy?, false)
      |> assign(:error, nil)
      |> assign(:selected_video_detail, nil)
      |> assign(:selected_channel_preview, nil)
      |> assign(:detail_loading?, false)
      |> assign(:preview_loading?, false)
      |> assign(:confirming_channel, nil)
      |> assign(:refresh_timer, nil)
      |> assign(:paste_url_modal_open?, false)
      |> assign(:pasted_url, "")
      |> assign(:paste_error, nil)
      |> assign(:paste_resolved_video, nil)
      |> assign(:paste_resolving?, false)
      |> assign(:paste_downloading?, false)
      |> assign(:paste_selected_profile_id, selected_profile_id)
      |> assign(:paste_download_destination, nil)

    socket =
      case session["prefill_url"] do
        url when is_binary(url) and url != "" ->
          assign(socket, paste_url_modal_open?: true, pasted_url: String.slice(url, 0, 2049))

        _ ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("restore_search", params, socket) do
    {:noreply, restore_search(params, socket)}
  end

  def handle_event(event, _params, %{assigns: %{loading?: true}} = socket)
      when event in [
             "view_video_details",
             "view_channel_preview",
             "download_video",
             "prompt_subscribe_channel",
             "confirm_subscribe_channel"
           ] do
    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query} = params, socket) do
    trimmed_query = String.trim(query)

    tab =
      case Map.get(params, "tab", to_string(socket.assigns.active_tab)) do
        "channels" -> :channels
        _ -> :videos
      end

    if trimmed_query == "" do
      {:noreply, assign(socket, error: "Please enter a search query.", loading?: false)}
    else
      YoutubeBrowser.cancel_operation(self())
      new_gen = (socket.assigns[:search_generation] || 0) + 1

      socket =
        socket
        |> cancel_async(:search_task)
        |> assign(:query, trimmed_query)
        |> assign(:active_tab, tab)
        |> assign(:search_tab, tab)
        |> assign(:search_generation, new_gen)
        |> assign(:results, if(tab == socket.assigns.active_tab, do: socket.assigns.results, else: []))
        |> assign(:loading?, true)
        |> assign(:busy?, false)
        |> assign(:error, nil)
        |> assign(:selected_video_detail, nil)
        |> assign(:selected_channel_preview, nil)
        |> assign(:detail_loading?, false)
        |> assign(:preview_loading?, false)
        |> remember_search()
        |> start_search_async(trimmed_query, tab, socket.assigns.selected_profile_id, new_gen)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab_str}, socket) do
    tab =
      case tab_str do
        "channels" -> :channels
        _ -> :videos
      end

    was_loading? = socket.assigns.loading?

    YoutubeBrowser.cancel_operation(self())
    new_gen = (socket.assigns[:search_generation] || 0) + 1

    socket =
      socket
      |> cancel_async(:search_task)
      |> assign(:active_tab, tab)
      |> assign(:search_tab, tab)
      |> assign(:search_generation, new_gen)
      |> assign(:results, [])
      |> assign(:loading?, false)
      |> assign(:selected_video_detail, nil)
      |> assign(:selected_channel_preview, nil)
      |> assign(:detail_loading?, false)
      |> assign(:preview_loading?, false)
      |> remember_search()

    if socket.assigns.query != "" and not was_loading? do
      socket =
        socket
        |> assign(:loading?, true)
        |> assign(:busy?, false)
        |> assign(:error, nil)
        |> start_search_async(socket.assigns.query, tab, socket.assigns.selected_profile_id, new_gen)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_profile", %{"profile_id" => profile_id_str}, socket) do
    new_profile_id =
      case Integer.parse(profile_id_str) do
        {id, _} -> id
        :error -> nil
      end

    socket = assign(socket, :selected_profile_id, new_profile_id)

    # Re-evaluate statuses of current results against newly selected profile
    updated_results = re_enrich_results(socket.assigns.results, socket.assigns.active_tab, new_profile_id)

    # Also re-enrich selected video detail or channel preview if open
    updated_detail =
      if socket.assigns.selected_video_detail do
        vid = socket.assigns.selected_video_detail.id
        statuses = Status.enrich_videos([vid], selected_profile_id: new_profile_id)
        Map.put(socket.assigns.selected_video_detail, :status, Map.get(statuses, vid))
      else
        nil
      end

    updated_preview =
      if socket.assigns.selected_channel_preview do
        preview = socket.assigns.selected_channel_preview
        vids = Enum.map(preview.videos, & &1.id)
        statuses = Status.enrich_videos(vids, selected_profile_id: new_profile_id)

        enriched_vids =
          Enum.map(preview.videos, fn v ->
            Map.put(v, :status, Map.get(statuses, v.id))
          end)

        %{preview | videos: enriched_vids}
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:results, updated_results)
     |> assign(:selected_video_detail, updated_detail)
     |> assign(:selected_channel_preview, updated_preview)
     |> remember_search()}
  end

  @impl true
  def handle_event("cancel_search", _params, socket) do
    YoutubeBrowser.cancel_operation(self())
    socket = cancel_async(socket, :search_task)
    {:noreply, assign(socket, loading?: false, error: "Search cancelled.")}
  end

  @impl true
  def handle_event("view_video_details", %{"id" => video_id}, socket) do
    socket = assign(socket, detail_loading?: true, error: nil)

    profile_id = socket.assigns.selected_profile_id
    caller = self()

    socket =
      start_async(socket, :detail_task, fn ->
        YoutubeBrowser.get_video_details(video_id, selected_profile_id: profile_id, caller: caller)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_video_details", _params, socket) do
    socket = cancel_async(socket, :detail_task)
    {:noreply, assign(socket, selected_video_detail: nil, detail_loading?: false)}
  end

  @impl true
  def handle_event("view_channel_preview", %{"id" => channel_id, "title" => title}, socket) do
    socket = assign(socket, preview_loading?: true, error: nil)

    profile_id = socket.assigns.selected_profile_id
    caller = self()

    socket =
      start_async(socket, :preview_task, fn ->
        case YoutubeBrowser.get_channel_preview(channel_id, selected_profile_id: profile_id, caller: caller) do
          {:ok, videos} -> {:ok, %{channel_id: channel_id, title: title, videos: videos}}
          error -> error
        end
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_channel_preview", _params, socket) do
    socket = cancel_async(socket, :preview_task)
    {:noreply, assign(socket, selected_channel_preview: nil, preview_loading?: false)}
  end

  @impl true
  def handle_event("open_paste_url_modal", _params, socket) do
    profile_id =
      cond do
        length(socket.assigns.profiles) == 1 ->
          hd(socket.assigns.profiles).id

        not is_nil(socket.assigns.selected_profile_id) ->
          socket.assigns.selected_profile_id

        true ->
          nil
      end

    {:noreply,
     socket
     |> assign(:paste_url_modal_open?, true)
     |> assign(:pasted_url, "")
     |> assign(:paste_error, nil)
     |> assign(:paste_resolved_video, nil)
     |> assign(:paste_resolving?, false)
     |> assign(:paste_downloading?, false)
     |> assign(:paste_selected_profile_id, profile_id)}
  end

  @impl true
  def handle_event("close_paste_url_modal", _params, socket) do
    YoutubeBrowser.cancel_operation(self())
    socket = cancel_async(socket, :resolve_pasted_url_task)

    {:noreply,
     socket
     |> assign(:paste_url_modal_open?, false)
     |> assign(:paste_resolving?, false)
     |> assign(:paste_downloading?, false)
     |> assign(:paste_resolved_video, nil)
     |> assign(:paste_error, nil)
     |> assign(:pasted_url, "")}
  end

  @impl true
  def handle_event("update_pasted_url", %{"url" => url}, socket) do
    trimmed = String.trim(url)

    resolved =
      if socket.assigns.paste_resolved_video && socket.assigns.pasted_url != trimmed do
        nil
      else
        socket.assigns.paste_resolved_video
      end

    {:noreply,
     socket
     |> assign(:pasted_url, url)
     |> assign(:paste_resolved_video, resolved)
     |> assign(:paste_error, nil)}
  end

  @impl true
  def handle_event("select_paste_profile", %{"profile_id" => profile_id_str}, socket) do
    new_profile_id =
      case Integer.parse(profile_id_str) do
        {id, _} -> id
        :error -> nil
      end

    updated_resolved =
      if socket.assigns.paste_resolved_video do
        vid = socket.assigns.paste_resolved_video.id
        statuses = Status.enrich_videos([vid], selected_profile_id: new_profile_id)
        Map.put(socket.assigns.paste_resolved_video, :status, Map.get(statuses, vid))
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:paste_selected_profile_id, new_profile_id)
     |> assign(:paste_resolved_video, updated_resolved)}
  end

  @impl true
  def handle_event("resolve_pasted_url", params, socket) do
    raw_url = Map.get(params, "url", socket.assigns.pasted_url)
    profile_id = socket.assigns.paste_selected_profile_id

    case UrlParser.parse(raw_url) do
      {:ok, %{video_id: video_id, canonical_url: _}} ->
        if is_nil(profile_id) do
          {:noreply, assign(socket, paste_error: "Please select a media profile before resolving.")}
        else
          caller = self()

          socket =
            socket
            |> cancel_async(:resolve_pasted_url_task)
            |> assign(:paste_resolving?, true)
            |> assign(:paste_error, nil)
            |> assign(:paste_resolved_video, nil)
            |> start_async(:resolve_pasted_url_task, fn ->
              fetch_video_details_matching(video_id, profile_id, caller)
            end)

          {:noreply, socket}
        end

      {:error, {:channel_or_playlist, message}} ->
        {:noreply, assign(socket, paste_error: message, paste_resolving?: false)}

      {:error, reason} ->
        {:noreply, assign(socket, paste_error: friendly_url_error(reason), paste_resolving?: false)}
    end
  end

  @impl true
  def handle_event("download_pasted_video", _params, socket) do
    video = socket.assigns.paste_resolved_video
    profile_id = socket.assigns.paste_selected_profile_id

    cond do
      socket.assigns.paste_downloading? ->
        {:noreply, socket}

      is_nil(video) ->
        {:noreply, assign(socket, paste_error: "Please resolve a video before downloading.")}

      is_nil(profile_id) ->
        {:noreply, assign(socket, paste_error: "Please select a media profile.")}

      true ->
        socket = assign(socket, paste_downloading?: true, paste_error: nil)

        case YoutubeBrowser.download_video(video.id, profile_id) do
          {:ok, outcome} ->
            msg =
              case outcome do
                :queued -> "Video download queued."
                :queued_paused -> "Video download queued (queue currently paused)."
                :indexing -> "Single-video source created; preparing download."
              end

            updated_results = re_enrich_results(socket.assigns.results, socket.assigns.active_tab, profile_id)

            {:noreply,
             socket
             |> put_flash(:info, msg)
             |> assign(:paste_download_destination, pasted_download_destination(video.id, profile_id, outcome, msg))
             |> assign(:paste_url_modal_open?, false)
             |> assign(:paste_downloading?, false)
             |> assign(:paste_resolved_video, nil)
             |> assign(:pasted_url, "")
             |> assign(:results, updated_results)}

          {:error, :migration_hold_active} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Action unavailable: Database migration review or transfer in progress.")}

          {:error, :already_present} ->
            statuses = Status.enrich_videos([video.id], selected_profile_id: profile_id)
            updated_video = Map.put(video, :status, Map.get(statuses, video.id))

            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_resolved_video, updated_video)
             |> assign(:paste_error, "Video is already present in your library.")}

          {:error, :already_queued} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Video is already queued or downloading.")}

          {:error, :source_disabled} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Cannot download: Source is currently disabled.")}

          {:error, :source_downloads_disabled} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Cannot download: Downloads are disabled for this source.")}

          {:error, :download_prevented} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Cannot download: Media item has downloads prevented.")}

          {:error, :missing_file} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Media file is missing on disk. Run a library repair to resolve.")}

          {:error, :storage_unverified} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Cannot download: Storage location is unverified.")}

          {:error, :storage_inaccessible} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Cannot download: Storage location is inaccessible.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:paste_downloading?, false)
             |> assign(:paste_error, "Download failed: #{friendly_download_error(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("download_video", %{"id" => video_id}, socket) do
    profile_id = socket.assigns.selected_profile_id

    if is_nil(profile_id) do
      {:noreply, put_flash(socket, :error, "Please select a media profile first.")}
    else
      case YoutubeBrowser.download_video(video_id, profile_id) do
        {:ok, outcome} ->
          msg =
            case outcome do
              :queued -> "Video download queued."
              :queued_paused -> "Video download queued (queue currently paused)."
              :indexing -> "Single-video source created; preparing download."
            end

          updated_results = re_enrich_results(socket.assigns.results, socket.assigns.active_tab, profile_id)

          {:noreply,
           socket
           |> put_flash(:info, msg)
           |> assign(:results, updated_results)
           |> assign(:selected_video_detail, nil)}

        {:error, :migration_hold_active} ->
          {:noreply,
           socket
           |> put_flash(:error, "Action unavailable: Database migration review or transfer in progress.")}

        {:error, :source_disabled} ->
          {:noreply,
           socket
           |> put_flash(:error, "Cannot download: Source is currently disabled.")}

        {:error, :source_downloads_disabled} ->
          {:noreply,
           socket
           |> put_flash(:error, "Cannot download: Source downloads are disabled.")}

        {:error, :policy_ineligible} ->
          {:noreply,
           socket
           |> put_flash(:error, "Cannot download: Video is ineligible under current source or profile policies.")}

        {:error, :storage_unverified} ->
          {:noreply,
           socket
           |> put_flash(:error, "Cannot download: Media storage is unverified.")}

        {:error, :storage_inaccessible} ->
          {:noreply,
           socket
           |> put_flash(:error, "Cannot download: Media storage is inaccessible.")}

        {:error, :download_prevented} ->
          {:noreply,
           socket
           |> put_flash(:error, "Download prevented by user or system policy.")}

        {:error, :already_present} ->
          {:noreply,
           socket
           |> put_flash(:info, "Video is already present in your library.")}

        {:error, :already_queued} ->
          {:noreply,
           socket
           |> put_flash(:info, "Video download is already in progress or queued.")}

        {:error, :missing_file} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Video record exists but file is missing on disk. Use the media details page to re-download."
           )}

        {:error, :ambiguous_copies} ->
          {:noreply,
           socket
           |> put_flash(:error, "Multiple copies found under this profile. Please manage via library.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to start download: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("prompt_subscribe_channel", %{"id" => channel_id} = params, socket) do
    if is_nil(socket.assigns.selected_profile_id) do
      {:noreply, put_flash(socket, :error, "Please select a media profile first.")}
    else
      title = Map.get(params, "title") || "YouTube Channel #{channel_id}"
      handle = Map.get(params, "handle")

      {:noreply, assign(socket, :confirming_channel, %{id: channel_id, title: title, handle: handle})}
    end
  end

  @impl true
  def handle_event("cancel_subscribe_channel", _params, socket) do
    {:noreply, assign(socket, :confirming_channel, nil)}
  end

  @impl true
  def handle_event("confirm_subscribe_channel", %{"id" => channel_id} = params, socket) do
    profile_id = socket.assigns.selected_profile_id

    if is_nil(profile_id) do
      {:noreply,
       socket
       |> put_flash(:error, "Please select a media profile first.")
       |> assign(:confirming_channel, nil)}
    else
      title = Map.get(params, "title") || "YouTube Channel #{channel_id}"

      case YoutubeBrowser.subscribe_channel(channel_id, profile_id, channel_title: title) do
        {:ok, _source} ->
          updated_results = re_enrich_results(socket.assigns.results, socket.assigns.active_tab, profile_id)

          {:noreply,
           socket
           |> put_flash(:info, "Successfully subscribed to #{title}. Initial indexing scheduled.")
           |> assign(:confirming_channel, nil)
           |> assign(:results, updated_results)}

        {:error, {:already_tracked, existing_source}} ->
          updated_results = re_enrich_results(socket.assigns.results, socket.assigns.active_tab, profile_id)

          msg =
            if existing_source.enabled do
              "Channel is already tracked in your library under \"#{existing_source.custom_name}\"."
            else
              "Channel exists in your library but is currently paused/disabled. Enable it in Source settings to resume."
            end

          {:noreply,
           socket
           |> put_flash(:info, msg)
           |> assign(:confirming_channel, nil)
           |> assign(:results, updated_results)}

        {:error, :ambiguous_copies} ->
          {:noreply,
           socket
           |> put_flash(:error, "Multiple channel sources already exist under this profile.")
           |> assign(:confirming_channel, nil)}

        {:error, :migration_hold_active} ->
          {:noreply,
           socket
           |> put_flash(:error, "Action unavailable: Database migration review or transfer in progress.")
           |> assign(:confirming_channel, nil)}

        {:error, :invalid_profile} ->
          {:noreply,
           socket
           |> put_flash(:error, "Invalid or missing media profile.")
           |> assign(:confirming_channel, nil)}

        {:error, :invalid_channel_id} ->
          {:noreply,
           socket
           |> put_flash(:error, "Invalid channel identifier.")
           |> assign(:confirming_channel, nil)}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to subscribe: #{inspect(reason)}")
           |> assign(:confirming_channel, nil)}
      end
    end
  end

  @impl true
  def handle_event("subscribe_channel", params, socket) do
    # Direct click routes to explicit confirmation prompt
    handle_event("prompt_subscribe_channel", params, socket)
  end

  # --- Async Result Handlers ---

  @impl true
  def handle_async(:search_task, {:ok, {task_tab, task_gen, {:ok, results}}}, socket) do
    if socket.assigns[:loading?] and
         task_gen == socket.assigns[:search_generation] and
         task_tab == socket.assigns.active_tab do
      {:noreply,
       socket
       |> assign(:results, re_enrich_results(results, socket.assigns.active_tab, socket.assigns.selected_profile_id))
       |> assign(:loading?, false)
       |> assign(:busy?, false)
       |> assign(:error, nil)}
    else
      {:noreply, assign(socket, loading?: false)}
    end
  end

  @impl true
  def handle_async(:search_task, {:ok, {_task_tab, task_gen, {:error, :busy}}}, socket) do
    if task_gen == socket.assigns[:search_generation] do
      {:noreply,
       socket
       |> assign(:loading?, false)
       |> assign(:busy?, true)
       |> assign(:error, "The search provider is currently busy. Please try again shortly.")}
    else
      {:noreply, assign(socket, loading?: false)}
    end
  end

  @impl true
  def handle_async(:search_task, {:ok, {_task_tab, task_gen, {:error, :rate_limited}}}, socket) do
    if task_gen == socket.assigns[:search_generation] do
      {:noreply,
       socket
       |> assign(:loading?, false)
       |> assign(:error, "Rate limit reached. Please wait a minute before searching again.")}
    else
      {:noreply, assign(socket, loading?: false)}
    end
  end

  @impl true
  def handle_async(:search_task, {:ok, {_task_tab, task_gen, {:error, :timeout}}}, socket) do
    if task_gen == socket.assigns[:search_generation] do
      {:noreply,
       socket
       |> assign(:loading?, false)
       |> assign(:error, "The search request timed out. Please try again.")}
    else
      {:noreply, assign(socket, loading?: false)}
    end
  end

  @impl true
  def handle_async(:search_task, {:ok, {_task_tab, task_gen, {:error, reason}}}, socket) do
    if task_gen == socket.assigns[:search_generation] do
      Logger.warning("YouTube search failed: #{inspect(reason)}")

      {:noreply,
       socket
       |> assign(:loading?, false)
       |> assign(:error, "Failed to fetch results from YouTube: #{format_error(reason)}")}
    else
      {:noreply, assign(socket, loading?: false)}
    end
  end

  # Fallback 2-tuple handlers for direct calls
  @impl true
  def handle_async(:search_task, {:ok, {:ok, results}}, socket) do
    if socket.assigns[:loading?] do
      {:noreply,
       socket
       |> assign(:results, re_enrich_results(results, socket.assigns.active_tab, socket.assigns.selected_profile_id))
       |> assign(:loading?, false)
       |> assign(:busy?, false)
       |> assign(:error, nil)}
    else
      {:noreply, assign(socket, loading?: false)}
    end
  end

  @impl true
  def handle_async(:search_task, {:ok, {:error, :busy}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:busy?, true)
     |> assign(:error, "The search provider is currently busy. Please try again shortly.")}
  end

  @impl true
  def handle_async(:search_task, {:ok, {:error, :rate_limited}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:error, "Rate limit reached. Please wait a minute before searching again.")}
  end

  @impl true
  def handle_async(:search_task, {:ok, {:error, :timeout}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:error, "The search request timed out. Please try again.")}
  end

  @impl true
  def handle_async(:search_task, {:ok, {:error, reason}}, socket) do
    Logger.warning("YouTube search failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:error, "Failed to fetch results from YouTube: #{format_error(reason)}")}
  end

  @impl true
  def handle_async(:search_task, {:exit, _reason}, socket) do
    {:noreply, assign(socket, loading?: false)}
  end

  @impl true
  def handle_async(:detail_task, {:ok, {:ok, detail}}, socket) do
    if socket.assigns[:detail_loading?] do
      current_profile_id = socket.assigns[:selected_profile_id]
      statuses = Status.enrich_videos([detail.id], selected_profile_id: current_profile_id)
      enriched_detail = Map.put(detail, :status, Map.get(statuses, detail.id))

      {:noreply,
       socket
       |> assign(:selected_video_detail, enriched_detail)
       |> assign(:detail_loading?, false)}
    else
      {:noreply, assign(socket, detail_loading?: false)}
    end
  end

  @impl true
  def handle_async(:detail_task, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:detail_loading?, false)
     |> assign(:error, "Failed to load video details: #{format_error(reason)}")}
  end

  @impl true
  def handle_async(:detail_task, {:exit, _}, socket) do
    {:noreply, assign(socket, detail_loading?: false)}
  end

  @impl true
  def handle_async(:preview_task, {:ok, {:ok, preview_data}}, socket) do
    if socket.assigns[:preview_loading?] do
      current_profile_id = socket.assigns[:selected_profile_id]
      vids = Enum.map(preview_data.videos, & &1.id)
      statuses = Status.enrich_videos(vids, selected_profile_id: current_profile_id)

      enriched_vids =
        Enum.map(preview_data.videos, fn v ->
          Map.put(v, :status, Map.get(statuses, v.id))
        end)

      {:noreply,
       socket
       |> assign(:selected_channel_preview, %{preview_data | videos: enriched_vids})
       |> assign(:preview_loading?, false)}
    else
      {:noreply, assign(socket, preview_loading?: false)}
    end
  end

  @impl true
  def handle_async(:preview_task, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:preview_loading?, false)
     |> assign(:error, "Failed to load channel preview: #{format_error(reason)}")}
  end

  @impl true
  def handle_async(:preview_task, {:exit, _}, socket) do
    {:noreply, assign(socket, preview_loading?: false)}
  end

  @impl true
  def handle_async(:resolve_pasted_url_task, {:ok, {:ok, detail}}, socket) do
    if socket.assigns[:paste_resolving?] do
      current_profile_id = socket.assigns[:paste_selected_profile_id]
      statuses = Status.enrich_videos([detail.id], selected_profile_id: current_profile_id)
      enriched_detail = Map.put(detail, :status, Map.get(statuses, detail.id))

      {:noreply,
       socket
       |> assign(:paste_resolved_video, enriched_detail)
       |> assign(:paste_resolving?, false)
       |> assign(:paste_error, nil)}
    else
      {:noreply, assign(socket, paste_resolving?: false)}
    end
  end

  @impl true
  def handle_async(:resolve_pasted_url_task, {:ok, {:error, :id_mismatch}}, socket) do
    {:noreply,
     socket
     |> assign(:paste_resolving?, false)
     |> assign(:paste_resolved_video, nil)
     |> assign(:paste_error, "Resolved video ID does not match the parsed URL.")}
  end

  @impl true
  def handle_async(:resolve_pasted_url_task, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:paste_resolving?, false)
     |> assign(:paste_resolved_video, nil)
     |> assign(:paste_error, "Could not resolve video: #{friendly_download_error(reason)}")}
  end

  @impl true
  def handle_async(:resolve_pasted_url_task, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:paste_resolving?, false)
     |> assign(:paste_resolved_video, nil)
     |> assign(:paste_error, "Video resolution timed out or was cancelled.")}
  end

  # --- Live PubSub Handlers ---

  @impl true
  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, schedule_coalesced_refresh(socket)}
  end

  @impl true
  def handle_info(%{topic: "job:progress", event: "update"}, socket) do
    {:noreply, schedule_coalesced_refresh(socket)}
  end

  @impl true
  def handle_info(:coalesced_status_refresh, socket) do
    socket = assign(socket, :refresh_timer, nil)
    profile_id = socket.assigns.selected_profile_id

    updated_results =
      if socket.assigns.results != [] do
        re_enrich_results(
          socket.assigns.results,
          socket.assigns.active_tab,
          profile_id
        )
      else
        []
      end

    updated_detail =
      if socket.assigns.selected_video_detail do
        detail = socket.assigns.selected_video_detail
        statuses = Status.enrich_videos([detail.id], selected_profile_id: profile_id)
        Map.put(detail, :status, Map.get(statuses, detail.id))
      else
        nil
      end

    updated_preview =
      if socket.assigns.selected_channel_preview do
        preview = socket.assigns.selected_channel_preview
        vids = Enum.map(preview.videos, & &1.id)
        statuses = Status.enrich_videos(vids, selected_profile_id: profile_id)

        enriched_vids =
          Enum.map(preview.videos, fn v ->
            Map.put(v, :status, Map.get(statuses, v.id))
          end)

        %{preview | videos: enriched_vids}
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:results, updated_results)
     |> assign(:selected_video_detail, updated_detail)
     |> assign(:selected_channel_preview, updated_preview)}
  end

  @impl true
  def handle_info(_unhandled, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if timer = socket.assigns[:refresh_timer] do
      Process.cancel_timer(timer)
    end

    :ok
  end

  # --- Internal Helpers ---

  defp schedule_coalesced_refresh(socket) do
    has_items? =
      (is_list(socket.assigns[:results]) and socket.assigns.results != []) or
        not is_nil(socket.assigns[:selected_video_detail]) or
        not is_nil(socket.assigns[:selected_channel_preview])

    if has_items? do
      if socket.assigns[:refresh_timer] do
        socket
      else
        timer = Process.send_after(self(), :coalesced_status_refresh, 500)
        assign(socket, :refresh_timer, timer)
      end
    else
      socket
    end
  end

  defp default_profile_id([single]), do: single.id
  defp default_profile_id(_), do: nil

  defp remember_search(socket) do
    push_event(socket, "browse:remember", %{
      q: socket.assigns.query,
      tab: socket.assigns.active_tab,
      profile: socket.assigns.selected_profile_id
    })
  end

  defp restore_search(%{"q" => query} = params, socket) when is_binary(query) do
    tab = if params["tab"] == "channels", do: :channels, else: :videos

    profile_id =
      case parse_search_profile(params["profile"]) do
        {id, ""} -> if Enum.any?(socket.assigns.profiles, &(&1.id == id)), do: id
        _ -> socket.assigns.selected_profile_id
      end

    desired = {String.trim(query), tab, profile_id}
    current = {socket.assigns.query, socket.assigns.active_tab, socket.assigns.selected_profile_id}

    if String.length(query) <= 200 and desired != current do
      socket = assign(socket, selected_profile_id: profile_id)

      if String.trim(query) == "" do
        YoutubeBrowser.cancel_operation(self())

        socket
        |> cancel_async(:search_task)
        |> assign(
          query: "",
          active_tab: tab,
          results: [],
          loading?: false,
          search_generation: socket.assigns.search_generation + 1
        )
      else
        {:noreply, socket} = handle_event("search", %{"query" => query, "tab" => to_string(tab)}, socket)
        socket
      end
    else
      socket
    end
  end

  defp restore_search(_params, socket), do: socket

  defp parse_search_profile(value) when is_binary(value), do: Integer.parse(value)
  defp parse_search_profile(_value), do: :error

  defp start_search_async(socket, query, :videos, profile_id, gen) do
    caller = self()

    start_async(socket, :search_task, fn ->
      res = YoutubeBrowser.search_videos(query, selected_profile_id: profile_id, caller: caller)
      {:videos, gen, res}
    end)
  end

  defp start_search_async(socket, query, :channels, profile_id, gen) do
    caller = self()

    start_async(socket, :search_task, fn ->
      res = YoutubeBrowser.search_channels(query, selected_profile_id: profile_id, caller: caller)
      {:channels, gen, res}
    end)
  end

  defp re_enrich_results([], _tab, _profile_id), do: []

  defp re_enrich_results(results, :videos, profile_id) do
    vids = Enum.map(results, & &1.id)
    statuses = Status.enrich_videos(vids, selected_profile_id: profile_id)

    Enum.map(results, fn r ->
      Map.put(r, :status, Map.get(statuses, r.id))
    end)
  end

  defp re_enrich_results(results, :channels, profile_id) do
    cids = Enum.map(results, & &1.id)
    statuses = Status.enrich_channels(cids, selected_profile_id: profile_id)

    Enum.map(results, fn r ->
      Map.put(r, :status, Map.get(statuses, r.id))
    end)
  end

  defp format_error(:busy), do: "Provider is busy"
  defp format_error(:timeout), do: "Request timed out"
  defp format_error(:rate_limited), do: "Rate limit reached"
  defp format_error(:cancelled), do: "Request cancelled"
  defp format_error({:exit_status, code}), do: "Command exited with status #{code}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @doc false
  def format_duration(nil), do: "--:--"

  def format_duration(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)

    if mins >= 60 do
      hours = div(mins, 60)
      rem_mins = rem(mins, 60)
      :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, rem_mins, secs]) |> to_string()
    else
      :io_lib.format("~2..0B:~2..0B", [mins, secs]) |> to_string()
    end
  end

  def format_duration(_), do: "--:--"

  @doc false
  def current_profile_name(profiles, selected_id) when is_list(profiles) do
    case Enum.find(profiles, &(&1.id == selected_id)) do
      %{name: name} -> name
      _ -> "Selected Profile"
    end
  end

  def current_profile_name(_, _), do: "Selected Profile"

  defp fetch_video_details_matching(video_id, profile_id, caller) do
    case YoutubeBrowser.get_video_details(video_id, selected_profile_id: profile_id, caller: caller) do
      {:ok, %{id: ^video_id} = detail} -> {:ok, detail}
      {:ok, _} -> {:error, :id_mismatch}
      error -> error
    end
  end

  defp pasted_download_destination(_video_id, _profile_id, :indexing, message) do
    %{message: message, href: ~p"/sources?type=videos", label: "View in Individual videos"}
  end

  defp pasted_download_destination(video_id, profile_id, _outcome, message) do
    status = Status.enrich_videos([video_id], selected_profile_id: profile_id)[video_id]

    case status do
      %{source_id: source_id, media_item_id: media_item_id}
      when not is_nil(source_id) and not is_nil(media_item_id) ->
        %{message: message, href: ~p"/sources/#{source_id}/media/#{media_item_id}", label: "View video"}

      _ ->
        %{message: message, href: ~p"/sources?type=videos", label: "View in Individual videos"}
    end
  end

  defp friendly_url_error(:empty_url), do: "Please enter a YouTube video URL."
  defp friendly_url_error(:url_too_long), do: "URL exceeds maximum permitted length (2,048 characters)."
  defp friendly_url_error(:unsupported_scheme), do: "Only HTTP and HTTPS URLs are supported."
  defp friendly_url_error(:credentials_not_allowed), do: "URLs containing credentials are not permitted."
  defp friendly_url_error(:non_default_port), do: "URLs with non-default ports are not permitted."
  defp friendly_url_error(:unsupported_host), do: "Please enter a valid YouTube URL (e.g. youtube.com or youtu.be)."
  defp friendly_url_error(:extra_path_segments), do: "URL contains unexpected extra path segments."
  defp friendly_url_error(:missing_video_id), do: "Could not find a valid video ID in the URL."
  defp friendly_url_error(:conflicting_video_id_parameters), do: "URL contains multiple conflicting video parameters."
  defp friendly_url_error(:invalid_video_id), do: "Invalid YouTube video ID."
  defp friendly_url_error(:invalid_path), do: "Invalid YouTube URL path."
  defp friendly_url_error(_), do: "Invalid YouTube URL."

  defp friendly_download_error(:timeout), do: "Request timed out."
  defp friendly_download_error(:busy), do: "The YouTube provider is currently busy. Please try again shortly."
  defp friendly_download_error(:rate_limited), do: "Rate limit reached. Please wait before retrying."
  defp friendly_download_error(:unavailable), do: "Video is unavailable or private."
  defp friendly_download_error(reason) when is_binary(reason), do: reason
  defp friendly_download_error(reason), do: inspect(reason)
end
