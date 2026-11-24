defmodule PinchflatWeb.Sources.SourceLive.IndexTableLive do
  use PinchflatWeb, :live_view
  on_mount PinchflatWeb.Plugs.PostgresMigrationGate
  use Pinchflat.Media.MediaQuery
  use Pinchflat.Sources.SourcesQuery

  import PinchflatWeb.CustomComponents.DatePicker, only: [date_picker: 1]
  import PinchflatWeb.Helpers.SortingHelpers
  import PinchflatWeb.Helpers.PaginationHelpers

  alias Pinchflat.Database
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Sources.SourceActions
  alias PinchflatWeb.Sources.SourceHTML

  @default_view_mode :grid
  @media_total_sort_keys [:pending_count, :downloaded_count, :media_size_bytes]
  @source_tabs [{"channels", "Channels & Playlists"}, {"videos", "Individual Videos"}]
  # How long a first click on a bulk action stays armed, and how long its button stays green after running.
  @bulk_arm_ms 4_000
  @bulk_done_ms 900
  @bulk_jobs [
    {"download_pending", :download_pending, "Download Pending"},
    {"redownload_existing", :redownload_existing, "Redownload Existing"},
    {"force_index", :force_index, "Force Index"},
    {"refresh_metadata", :refresh_metadata, "Refresh Metadata"},
    {"sync_files", :sync_files, "Sync Files on Disk"}
  ]

  defdelegate source_status(source, downloading?), to: SourceHTML

  @doc """
  Returns the effective retention as a short value for the source table, such as
  "30 days" or "Off". The full wording, including where it comes from, is
  `SourceHTML.retention_policy_label/1`.
  """
  def retention_short_label(source) do
    days =
      case source do
        %{retention_period_days: days} when is_integer(days) -> days
        %{media_profile: %{retention_period_days: days}} -> days
        _ -> nil
      end

    case days do
      days when days in [nil, 0] -> "Off"
      1 -> "1 day"
      days -> "#{days} days"
    end
  end

  @doc """
  Returns the poster URL used by the source library card.

  The endpoint applies the same artwork fallback as the podcast feed, so a
  source poster, fanart image, or downloaded media thumbnail can be used.
  """
  def source_poster_url(source), do: source |> source_struct() |> SourceHTML.poster_preview_url()

  @doc """
  Returns the initials used while a source poster is unavailable.
  """
  def source_initials(source), do: SourceHTML.source_initials(source)
  defdelegate cutoff_date_presets(), to: SourceHTML

  @doc """
  Returns the tabs shown above the source list as `{type, title}` pairs.
  """
  def source_tabs, do: @source_tabs

  @doc """
  Returns the source list path for a tab, keeping the table view when it is selected.
  The poster grid is the default view, so it is left out of the URL.
  """
  def source_tab_path(type, :table), do: ~p"/sources?#{[type: type, view: "table"]}"
  def source_tab_path(type, _view_mode), do: ~p"/sources?#{[type: type]}"

  @doc """
  Returns the lowercase noun used in messages about a source tab.
  """
  def source_type_noun(:videos), do: "individual videos"
  def source_type_noun(:channels), do: "channels & playlists"

  @doc """
  Returns the title-cased name of a source tab, for buttons.
  """
  def source_type_title(:videos), do: "Individual Videos"
  def source_type_title(:channels), do: "Channels & Playlists"

  @doc """
  Describes source download progress without treating an unknown or empty
  denominator as complete.

  Returns a map with `:state`, `:label`, and either a `:percent` or `nil`.
  """
  def source_progress(%{media_count: nil}),
    do: %{state: :unknown, label: "Progress unavailable: total unknown", percent: nil}

  def source_progress(%{media_count: 0}), do: %{state: :empty, label: "No indexed media yet", percent: 0}

  def source_progress(%{media_count: total, downloaded_count: downloaded}) when total > 0 do
    percent = min(div(downloaded * 100, total), 100)
    %{state: :known, label: "#{downloaded} of #{total} indexed items downloaded", percent: percent}
  end

  attr :source, :map, required: true
  attr :tooltip_position, :string, default: "top"

  defp source_delete_button(assigns) do
    ~H"""
    <.icon_button
      icon_name="hero-trash"
      tooltip="Delete"
      tooltip_position={@tooltip_position}
      icon_class="h-5 w-5 text-theme-error"
      size="compact"
      aria-label={"Delete #{@source.custom_name}"}
      phx-click={delete_source_js(@source)}
    />
    """
  end

  defp delete_source_js(source) do
    JS.push("confirm_delete", value: %{id: source.id}) |> show_modal("delete-selected-sources-modal")
  end

  attr :source, :map, required: true
  attr :return_to, :string, required: true
  attr :tooltip_position, :string, default: "top"
  attr :fold_edit_delete, :boolean, default: false, doc: "list Edit and Delete in the menu when the table is narrow"

  defp source_row_actions(assigns) do
    ~H"""
    <SourceHTML.source_actions_menu
      edit_path={@fold_edit_delete && ~p"/sources/#{@source.id}/edit"}
      on_delete={@fold_edit_delete && delete_source_js(@source)}
      row_option_class={@fold_edit_delete && "hidden @max-4xl:flex"}
      source={@source}
      pending_count={@source.pending_count}
      downloaded_count={@source.downloaded_count}
      return_to={@return_to}
      icon_name="hero-ellipsis-vertical-solid"
      aria_label={"More actions for #{@source.custom_name}"}
      tooltip="More actions"
      tooltip_position={@tooltip_position}
    />
    """
  end

  attr :source, :map, required: true
  attr :id, :string, default: nil
  attr :show_icon, :boolean, default: false
  attr :class, :string, default: nil

  defp source_retention(assigns) do
    ~H"""
    <.tooltip
      position="top"
      tooltip={"Retention: #{SourceHTML.retention_policy_label(@source)}. Age is counted from download time."}
      tooltip_class="text-center"
    >
      <span id={@id} class={["inline-flex items-center gap-1 whitespace-nowrap", @class]}>
        <.icon :if={@show_icon} name="hero-archive-box-x-mark" class="h-4 w-4" aria-hidden="true" />
        {retention_short_label(@source)}<span class="sr-only">, {SourceHTML.retention_policy_label(@source)}</span>
      </span>
    </.tooltip>
    """
  end

  attr :action, :string, required: true
  attr :label, :string, required: true
  attr :confirm_label, :string, required: true
  attr :done_label, :string, required: true
  attr :icon, :string, required: true
  attr :armed, :boolean, required: true
  attr :done, :boolean, required: true
  attr :disabled, :boolean, default: false

  # The first click arms the action and the second runs it; the button then turns green briefly.
  defp bulk_action_button(assigns) do
    ~H"""
    <.button
      type="button"
      variant={if @done, do: "success", else: "outline"}
      size="compact"
      class={["gap-1.5 transition-colors duration-300", @armed && "theme-confirm-pending"]}
      disabled={@disabled}
      phx-click="bulk_action"
      phx-value-action={@action}
      data-armed={to_string(@armed)}
    >
      <.icon name={if @done, do: "hero-check", else: @icon} class="h-4 w-4" />
      {cond do
        @done -> @done_label
        @armed -> @confirm_label
        true -> @label
      end}
    </.button>
    """
  end

  attr :source, :map, required: true
  attr :media_profiles, :list, required: true
  attr :text_class, :string, default: "max-w-48 truncate"

  defp source_profile_picker(assigns) do
    ~H"""
    <.button_dropdown
      text={@source.media_profile.name}
      text_class={@text_class}
      aria_label={"#{@source.media_profile.name}, change the media profile for #{@source.custom_name}"}
      tooltip="Change Media Profile"
      tooltip_position="top"
      variant="outline"
      size="compact"
      align="start"
      class="w-fit"
    >
      <:option :for={profile <- @media_profiles}>
        <button
          type="button"
          phx-click="assign_source_profile"
          phx-value-id={@source.id}
          phx-value-profile_id={profile.id}
          x-on:click="dropdownOpen = false"
          disabled={profile.id == @source.media_profile_id}
          aria-current={if profile.id == @source.media_profile_id, do: "true"}
          class="gap-1.5 px-2.5 disabled:cursor-default"
        >
          <.icon
            name="hero-check"
            class={"h-4 w-4 shrink-0 text-theme-primary #{if profile.id != @source.media_profile_id, do: "invisible"}"}
            aria-hidden="true"
          />
          <span class="min-w-0 truncate">{profile.name}</span>
        </button>
      </:option>
    </.button_dropdown>
    """
  end

  defp bulk_jobs, do: @bulk_jobs

  defp notice_kind({:success, _text}), do: :info
  defp notice_kind({:error, _text}), do: :error

  defp notice_title({:success, _text}), do: "Done"
  defp notice_title({:error, _text}), do: "Something went wrong"

  defp notice_text({_kind, text}), do: text

  defp toggle_cutoff_panel(js \\ %JS{}) do
    js
    |> JS.toggle(to: "#selected-source-cutoff", display: "block")
    |> JS.toggle_class("rotate-180", to: "#selected-source-cutoff-chevron")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#selected-source-cutoff-toggle")
  end

  defp hide_cutoff_panel(js) do
    js
    |> JS.hide(to: "#selected-source-cutoff")
    |> JS.remove_class("rotate-180", to: "#selected-source-cutoff-chevron")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#selected-source-cutoff-toggle")
  end

  def mount(_params, session, socket) do
    if connected?(socket) do
      PinchflatWeb.Endpoint.subscribe("job:state")
    end

    limit = session["results_per_page"]
    source_type = if session["source_type"] == "videos", do: :videos, else: :channels

    initial_params =
      Map.merge(
        %{
          sort_key: session["initial_sort_key"],
          source_type: source_type,
          return_to: if(source_type == :videos, do: ~p"/sources?type=videos", else: ~p"/sources"),
          sort_direction: session["initial_sort_direction"],
          view_mode: normalize_view_mode(session["initial_view_mode"]),
          grid_sort: {session["initial_sort_key"], session["initial_sort_direction"]},
          refresh_pending: false,
          selected_ids: MapSet.new(),
          selection_scope: :page,
          notice: nil,
          armed: nil,
          done_action: nil,
          delete_ids: [],
          job_running: nil,
          notice_id: 0,
          downloading_ids: MapSet.new(),
          media_profiles: Enum.reject(Profiles.list_media_profiles(), & &1.marked_for_deletion_at),
          timezone: Application.fetch_env!(:pinchflat, :timezone)
        },
        get_pagination_attributes(base_sources_query(source_type), 1, limit)
      )

    socket
    |> assign(initial_params)
    |> set_sources()
    |> then(&{:ok, &1})
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    new_page = update_page_number(assigns.page, direction, assigns.total_pages)

    socket
    |> keep_selection_across_pages()
    |> assign(get_pagination_attributes(base_sources_query(assigns.source_type), new_page, assigns.limit))
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def handle_event("sort_update", %{"sort_key" => sort_key}, %{assigns: assigns} = socket) do
    new_sort_key = String.to_existing_atom(sort_key)

    new_params = %{
      sort_key: new_sort_key,
      sort_direction: get_sort_direction(assigns.sort_key, new_sort_key, assigns.sort_direction)
    }

    socket
    |> keep_selection_across_pages()
    |> assign(new_params)
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def handle_event("assign_source_profile", %{"id" => id, "profile_id" => profile_id}, socket) do
    source = Enum.find(socket.assigns.sources, &(to_string(&1.id) == id))
    profile = Enum.find(socket.assigns.media_profiles, &(to_string(&1.id) == profile_id))

    # The new profile name on the picker confirms the change, so only a failure gets a toast.
    if source && profile && match?({:ok, _}, Sources.assign_selected_sources_profile([id], profile_id)) do
      {:noreply, set_sources(socket)}
    else
      notice = {:error, "Could not change the media profile. Reload the page and try again."}
      {:noreply, socket |> put_notice(notice) |> set_sources()}
    end
  end

  # Bulk actions run on a second click for the same selection, within @bulk_arm_ms.
  def handle_event("bulk_action", %{"action" => action}, socket) when action in ["pause", "resume"] do
    bulk_click(socket, String.to_existing_atom(action))
  end

  def handle_event("bulk_profile", %{"profile_id" => profile_id}, socket) do
    bulk_click(socket, {:profile, to_string(profile_id)})
  end

  def handle_event("bulk_job", %{"action" => name}, socket) do
    case {List.keyfind(@bulk_jobs, name, 0), socket.assigns.job_running} do
      {{_name, job, _label}, nil} -> bulk_click(socket, {:job, job})
      _ignored -> {:noreply, socket}
    end
  end

  def handle_event("view_change", %{"view" => view_mode}, socket) do
    view_mode = normalize_view_mode(view_mode)
    same_order? = view_sort(socket.assigns) == view_sort(%{socket.assigns | view_mode: view_mode})

    if same_order? do
      {:noreply, assign(socket, :view_mode, view_mode)}
    else
      socket
      |> keep_selection_across_pages()
      |> assign(:view_mode, view_mode)
      |> set_sources()
      |> then(&{:noreply, &1})
    end
  end

  def handle_event("toggle_select_all", _params, %{assigns: assigns} = socket) do
    if all_selected?(assigns.selected_ids, assigns.total_record_count),
      do: clear_selection(socket),
      else: select_all(socket)
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    ids = if Enum.any?(socket.assigns.sources, &(to_string(&1.id) == to_string(id))), do: [to_string(id)], else: []
    {:noreply, assign(socket, :delete_ids, ids)}
  end

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, :delete_ids, Enum.sort(socket.assigns.selected_ids))}
  end

  def handle_event("select_all", _params, socket), do: select_all(socket)

  def handle_event("clear_selection", _params, socket), do: clear_selection(socket)

  def handle_event("toggle_source_selection", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    if Enum.any?(socket.assigns.sources, &(to_string(&1.id) == id)) do
      selected = if MapSet.member?(selected, id), do: MapSet.delete(selected, id), else: MapSet.put(selected, id)
      {:noreply, assign(socket, :selected_ids, selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, throttled_set_sources(socket)}
  end

  def handle_info({:disarm_bulk, ref}, %{assigns: %{armed: {_action, _ids, ref}}} = socket) do
    {:noreply, assign(socket, :armed, nil)}
  end

  def handle_info({:disarm_bulk, _ref}, socket), do: {:noreply, socket}

  def handle_info({:clear_done, action}, %{assigns: %{done_action: action}} = socket) do
    {:noreply, assign(socket, :done_action, nil)}
  end

  def handle_info({:clear_done, _action}, socket), do: {:noreply, socket}

  def handle_info(:throttled_refresh, socket) do
    {:noreply, socket |> assign(:refresh_pending, false) |> set_sources()}
  end

  def handle_info({:source_enabled_updated, _source_id}, socket) do
    {:noreply, set_sources(socket)}
  end

  def handle_async(:bulk_job, {:ok, {job, {:ok, summary}}}, socket) do
    kind = if summary.failed > 0, do: :error, else: :success
    {:noreply, socket |> assign(:job_running, nil) |> put_notice({kind, bulk_job_message(job, summary)})}
  end

  def handle_async(:bulk_job, {:ok, {_job, {:error, _reason}}}, socket) do
    notice = {:error, "Nothing was queued. Refresh and select up to #{Sources.selection_limit()} available sources."}
    {:noreply, socket |> assign(:job_running, nil) |> put_notice(notice)}
  end

  def handle_async(:bulk_job, {:exit, _reason}, socket) do
    notice = {:error, "Could not queue this action. Check diagnostics and try again."}
    {:noreply, socket |> assign(:job_running, nil) |> put_notice(notice)}
  end

  defp sort_attr(:pending_count), do: dynamic([s, mp, dl, pe], coalesce(pe.pending_count, 0))
  defp sort_attr(:downloaded_count), do: dynamic([s, mp, dl], coalesce(dl.downloaded_count, 0))
  defp sort_attr(:media_size_bytes), do: dynamic([s, mp, dl], coalesce(dl.media_size_bytes, 0))
  defp sort_attr(:media_profile_name), do: dynamic([s, mp], fragment("LOWER(?)", mp.name))

  defp sort_attr(:custom_name) do
    if Database.postgres?() do
      dynamic([s], fragment("LOWER(?)", s.custom_name))
    else
      dynamic([s], fragment("? COLLATE NOCASE", s.custom_name))
    end
  end

  defp sort_attr(:enabled), do: dynamic([s], s.enabled)
  defp sort_attr(:collection_type), do: dynamic([s], s.collection_type)

  defp normalize_view_mode(mode) when mode in [:table, "table"], do: :table
  defp normalize_view_mode(mode) when mode in [:grid, "grid"], do: :grid
  defp normalize_view_mode(_mode), do: @default_view_mode

  defp source_struct(%Source{} = source), do: source
  defp source_struct(source), do: struct(Source, source)

  defp set_sources(%{assigns: assigns} = socket) do
    {sort_key, sort_direction} = view_sort(assigns)
    order = [{sort_direction, sort_attr(sort_key)}, asc: :id]

    sources =
      if sort_key in @media_total_sort_keys do
        # Ordering by a media total needs that total for every source before the page is cut.
        sources_query(assigns.source_type, nil)
        |> order_by(^order)
        |> limit(^assigns.limit)
        |> offset(^assigns.offset)
        |> Repo.all()
      else
        page_ids =
          base_sources_query(assigns.source_type)
          |> order_by(^order)
          |> limit(^assigns.limit)
          |> offset(^assigns.offset)
          |> select([s], s.id)
          |> Repo.all()

        sources_query(assigns.source_type, page_ids)
        |> where([s], s.id in ^page_ids)
        |> order_by(^order)
        |> Repo.all()
      end

    # A page selection only covers the visible sources; "select all" keeps sources on other pages.
    selected_ids =
      if assigns.selection_scope == :all,
        do: assigns.selected_ids,
        else: MapSet.intersection(assigns.selected_ids, MapSet.new(sources, &to_string(&1.id)))

    assign(socket, %{
      sources: sources,
      downloading_ids: Sources.downloading_source_ids(Enum.map(sources, & &1.id)),
      selected_ids: selected_ids
    })
  end

  # Table header sorting applies to the table only; the grid keeps the default order.
  defp view_sort(%{view_mode: :grid, grid_sort: grid_sort}), do: grid_sort
  defp view_sort(assigns), do: {assigns.sort_key, assigns.sort_direction}

  defp bulk_click(%{assigns: assigns} = socket, action) do
    ids = Enum.sort(assigns.selected_ids)

    cond do
      ids == [] ->
        {:noreply, socket}

      armed?(assigns.armed, action, ids) ->
        run_bulk_action(assign(socket, :armed, nil), action, ids)

      true ->
        ref = make_ref()
        Process.send_after(self(), {:disarm_bulk, ref}, @bulk_arm_ms)
        {:noreply, assign(socket, :armed, {action, ids, ref})}
    end
  end

  defp armed?({action, ids, _ref}, action, ids), do: true
  defp armed?(_armed, _action, _ids), do: false

  defp armed_for?(armed, action, selected_ids), do: armed?(armed, action, Enum.sort(selected_ids))

  # Queuing can take a while for many sources, so it runs off the LiveView process.
  defp run_bulk_action(socket, {:job, job}, ids) do
    socket
    |> assign(:job_running, job)
    |> start_async(:bulk_job, fn -> {job, SourceActions.run(job, ids)} end)
    |> then(&{:noreply, &1})
  end

  defp run_bulk_action(socket, action, ids) do
    result =
      case action do
        :pause -> Sources.pause_selected_sources(ids)
        :resume -> Sources.resume_selected_sources(ids)
        {:profile, profile_id} -> Sources.assign_selected_sources_profile(ids, profile_id)
      end

    done = if match?({:profile, _}, action), do: :profile, else: action

    case result do
      {:ok, _sources} ->
        Process.send_after(self(), {:clear_done, done}, @bulk_done_ms)
        {:noreply, socket |> assign(:done_action, done) |> set_sources()}

      {:error, _reason} ->
        notice =
          {:error, "Nothing changed. Refresh and select up to #{Sources.selection_limit()} available sources."}

        {:noreply, put_notice(socket, notice)}
    end
  end

  defp put_notice(socket, notice), do: assign(socket, notice: notice, notice_id: socket.assigns.notice_id + 1)

  defp bulk_job_message(job, summary) do
    {_name, _job, label} = List.keyfind(@bulk_jobs, job, 1)
    noun = if summary.sources == 1, do: "source", else: "sources"

    counts =
      if summary.queued + summary.duplicates + summary.failed == 0 do
        "nothing to queue"
      else
        [
          "#{summary.queued} queued",
          summary.duplicates > 0 && "#{summary.duplicates} already queued",
          summary.failed > 0 && "#{summary.failed} failed"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(", ")
      end

    skipped = if summary.skipped > 0, do: " #{summary.skipped} skipped because Download Media is off.", else: ""
    "#{label} for #{summary.sources} #{noun}: #{counts}.#{skipped}"
  end

  # Selects every source in the tab. Past the bulk action limit it
  # selects the page instead, and the selection banner explains why.
  defp select_all(%{assigns: assigns} = socket) do
    if assigns.total_record_count <= Sources.selection_limit() do
      ids =
        base_sources_query(assigns.source_type)
        |> select([s], s.id)
        |> Repo.all()
        |> MapSet.new(&to_string/1)

      {:noreply, assign(socket, selected_ids: ids, selection_scope: :all)}
    else
      page_ids = MapSet.new(assigns.sources, &to_string(&1.id))
      {:noreply, assign(socket, selected_ids: page_ids, selection_scope: :page)}
    end
  end

  defp clear_selection(socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new(), selection_scope: :page)}
  end

  # A page selection ends when the page or order changes; a "select all" selection does not.
  defp keep_selection_across_pages(%{assigns: %{selection_scope: :all}} = socket), do: socket
  defp keep_selection_across_pages(socket), do: assign(socket, :selected_ids, MapSet.new())

  defp select_all_header(assigns) do
    ~H"""
    <.input
      type="checkbox"
      id="source-select-all-table"
      name="source_select_all_table"
      label="Select every source"
      label_class="sr-only"
      checked={all_selected?(@selected_ids, @total_record_count)}
      disabled={@sources == []}
      phx-click="toggle_select_all"
    />
    """
  end

  # Selected ids only ever come from the current tab and search, so a full count means all of them.
  defp all_selected?(selected_ids, total), do: total > 0 and MapSet.size(selected_ids) >= total

  defp page_selected?([], _selected_ids), do: false
  defp page_selected?(sources, selected_ids), do: Enum.all?(sources, &MapSet.member?(selected_ids, to_string(&1.id)))

  # Confirms a selection that reaches past this page, or offers one once the page is ticked.
  defp show_selection_banner?(:all, sources, selected_ids, total),
    do: MapSet.size(selected_ids) > 0 and total > length(sources)

  defp show_selection_banner?(_scope, sources, selected_ids, total),
    do: total > length(sources) and page_selected?(sources, selected_ids)

  defp selection_limit, do: Sources.selection_limit()

  @refresh_throttle_ms 3_000

  defp throttled_set_sources(socket) do
    if Map.get(socket.assigns, :refresh_pending, false) do
      socket
    else
      Process.send_after(self(), :throttled_refresh, @refresh_throttle_ms)

      socket
      |> assign(:refresh_pending, true)
      |> set_sources()
    end
  end

  defp base_sources_query(source_type) do
    from s in Source,
      as: :source,
      inner_join: mp in assoc(s, :media_profile),
      where: ^source_type_filter(source_type),
      where: is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at)
  end

  # `source_ids` limits the media totals to the sources on the current page; nil totals every source.
  defp sources_query(source_type, source_ids) do
    for_sources = if source_ids, do: dynamic([m], m.source_id in ^source_ids), else: true

    downloaded_subquery =
      from(
        m in MediaItem,
        select: %{
          downloaded_count: count(m.id),
          source_id: m.source_id,
          media_size_bytes: type(sum(m.media_size_bytes), :integer)
        },
        where: ^MediaQuery.downloaded(),
        where: ^for_sources,
        group_by: m.source_id
      )

    pending_subquery =
      from(
        m in MediaItem,
        as: :media_item,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        select: %{pending_count: count(m.id), source_id: m.source_id},
        where: ^MediaQuery.pending(),
        where: ^for_sources,
        group_by: m.source_id
      )

    indexed_subquery =
      from(
        m in MediaItem,
        select: %{media_count: count(m.id), source_id: m.source_id},
        where: ^for_sources,
        group_by: m.source_id
      )

    from [s, mp] in base_sources_query(source_type),
      left_join: d in subquery(downloaded_subquery),
      on: d.source_id == s.id,
      left_join: p in subquery(pending_subquery),
      on: p.source_id == s.id,
      left_join: i in subquery(indexed_subquery),
      on: i.source_id == s.id,
      left_join: md in assoc(s, :metadata),
      preload: [media_profile: mp, metadata: md],
      select: map(s, ^Source.__schema__(:fields)),
      select_merge: %{
        downloaded_count: coalesce(d.downloaded_count, 0),
        pending_count: coalesce(p.pending_count, 0),
        media_size_bytes: coalesce(d.media_size_bytes, 0),
        media_count: coalesce(i.media_count, 0)
      }
  end

  defp source_type_filter(:videos), do: dynamic([s], s.collection_type == :video)
  defp source_type_filter(:channels), do: dynamic([s], is_nil(s.collection_type) or s.collection_type != :video)
end
