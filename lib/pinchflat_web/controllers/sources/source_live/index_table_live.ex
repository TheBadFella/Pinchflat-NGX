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
  @max_search_term_length 200
  @source_tabs [{"channels", "Channels & Playlists"}, {"videos", "Individual Videos"}]
  # How long a first click on a bulk action stays armed, and how long its button stays green after running.
  @bulk_arm_ms 4_000
  # A confirming click sooner than this after arming is ignored, so a double-click can't run an action.
  @bulk_ripen_ms 400
  @bulk_done_ms 900

  defdelegate source_status(source, downloading?), to: SourceHTML

  @doc """
  Returns the effective retention as a short value for the source table, such as
  "30 Days" or "Off". The full wording, including where it comes from, is
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
      1 -> "1 Day"
      days -> "#{days} Days"
    end
  end

  @doc """
  Returns how often a source is indexed as a short value for the source list,
  such as "Daily" or "10 Min" for fast indexing, and the full wording for its
  tooltip.

  Returns `{short_label, full_label}`.
  """
  def index_frequency_labels(%{fast_index: true}),
    do: {"10 Min", "Fast indexing checks for new uploads every 10 minutes, with a full index monthly"}

  def index_frequency_labels(%{index_frequency_minutes: minutes}) when is_integer(minutes) and minutes > 0 do
    short =
      case minutes do
        1440 -> "Daily"
        10_080 -> "Weekly"
        43_200 -> "Monthly"
        60 -> "Hourly"
        minutes when rem(minutes, 60) == 0 -> "#{div(minutes, 60)} Hours"
        minutes -> "#{minutes} Min"
      end

    {short, "Indexed every #{index_frequency_phrase(minutes)}"}
  end

  def index_frequency_labels(_source), do: {"Once", "Indexed only once, when the source was added"}

  defp index_frequency_phrase(1440), do: "day"
  defp index_frequency_phrase(10_080), do: "week"
  defp index_frequency_phrase(43_200), do: "30 days"
  defp index_frequency_phrase(60), do: "hour"
  defp index_frequency_phrase(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} hours"
  defp index_frequency_phrase(minutes), do: "#{minutes} minutes"

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
  Returns the lowercase noun used in search messages for a source tab.
  """
  def source_type_noun(:videos), do: "individual videos"
  def source_type_noun(:channels), do: "channels & playlists"

  @doc """
  Returns the title-cased name of a source tab, for buttons.
  """
  def source_type_title(:videos), do: "Individual Videos"
  def source_type_title(:channels), do: "Channels & Playlists"

  @doc """
  Trims a search term and returns nil when nothing is left to search for.
  Long terms are cut to #{@max_search_term_length} characters.
  """
  def normalize_search_term(term) when is_binary(term) do
    case term |> String.trim() |> String.slice(0, @max_search_term_length) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_search_term(_term), do: nil

  @doc """
  Describes how far a source is through the items it is set to download.

  The total is downloaded plus pending, so a caught-up source reaches 100%.
  Pending already leaves out items skipped by the cutoff, title filter,
  duration limits, format preference, availability rules, keep-newest limit
  and Prevent Download, and the label names how many indexed items that is.
  Items whose files retention removed are no longer downloaded or pending, so
  they count as skipped too.

  Returns a map with `:state`, `:label`, and either a `:percent` or `nil`.
  """
  def source_progress(%{media_count: nil}),
    do: %{state: :unknown, label: "Progress unavailable: total unknown", percent: nil}

  def source_progress(%{media_count: 0}), do: %{state: :empty, label: "No indexed media yet", percent: 0}

  def source_progress(%{media_count: indexed, downloaded_count: downloaded, pending_count: pending})
      when indexed > 0 do
    to_download = downloaded + pending
    skipped = skipped_suffix(max(indexed - to_download, 0))

    if to_download == 0 do
      %{state: :all_skipped, label: "Nothing to download#{skipped}", percent: nil}
    else
      percent = min(div(downloaded * 100, to_download), 100)
      %{state: :known, label: "#{downloaded} of #{to_download} downloaded#{skipped}", percent: percent}
    end
  end

  defp skipped_suffix(0), do: ""
  defp skipped_suffix(skipped), do: " · #{skipped} skipped"

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
    assigns =
      assign(assigns,
        policy: SourceHTML.retention_policy_label(assigns.source),
        profile_default:
          retention_short_label(%{retention_period_days: nil, media_profile: assigns.source.media_profile})
      )

    ~H"""
    <.button_dropdown
      tooltip={"Retention: #{@policy}. Age is counted from download time. Click to change."}
      tooltip_position="top"
      tooltip_class="text-center"
      class={"w-fit #{@class}"}
    >
      <:trigger>
        <span id={@id} class="inline-flex items-center gap-1 whitespace-nowrap">
          <.icon :if={@show_icon} name="hero-archive-box-x-mark" class="h-4 w-4" aria-hidden="true" />
          {retention_short_label(@source)}<span class="sr-only">, {@policy}. Change retention</span>
        </span>
      </:trigger>
      <:option>
        <form
          id={"#{@id}-form"}
          phx-submit="set_source_retention"
          class="w-64 px-4 py-2 text-left"
          x-on:submit="dropdownOpen = false"
        >
          <div class="space-y-2">
            <input type="hidden" name="source_id" value={@source.id} />
            <.input
              type="number"
              id={"#{@id}-days"}
              name="retention_period_days"
              value={@source.retention_period_days}
              label="Retention override (days)"
              placeholder={"Inherit (#{@profile_default})"}
              min="0"
              step="1"
            />
            <p class="text-xs text-theme-on-surface-muted">
              Leave blank to follow the media profile ({@profile_default}). Enter 0 to turn off age-based cleanup.
            </p>
            <.button type="submit" size="compact" class="w-full">Apply</.button>
          </div>
        </form>
      </:option>
    </.button_dropdown>
    """
  end

  attr :source, :map, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :show_icon, :boolean, default: false

  defp source_index_frequency(assigns) do
    {short, full} = index_frequency_labels(assigns.source)
    assigns = assign(assigns, short: short, full: full, locked: index_frequency_locked?(assigns.source))

    ~H"""
    <.tooltip :if={@locked} position="top" tooltip={"#{@full}."} tooltip_class="text-center">
      <span id={@id} class={["inline-flex items-center gap-1 whitespace-nowrap", @class]}>
        <.icon :if={@show_icon} name="hero-clock" class="h-4 w-4 text-theme-tertiary" aria-hidden="true" />
        {@short}<span class="sr-only">, {@full}</span>
      </span>
    </.tooltip>
    <.button_dropdown
      :if={!@locked}
      tooltip={"#{@full}. Click to change."}
      tooltip_position="top"
      tooltip_class="text-center"
      class={"w-fit #{@class}"}
    >
      <:trigger>
        <span id={@id} class="inline-flex items-center gap-1 whitespace-nowrap">
          <.icon :if={@show_icon} name="hero-clock" class="h-4 w-4 text-theme-tertiary" aria-hidden="true" />
          {@short}<span class="sr-only">, {@full}. Change index frequency</span>
        </span>
      </:trigger>
      <:option :for={{label, minutes} <- SourceHTML.friendly_index_frequencies()}>
        <button
          type="button"
          phx-click="set_source_index_frequency"
          phx-value-id={@source.id}
          phx-value-minutes={minutes}
          x-on:click="dropdownOpen = false"
          disabled={minutes == @source.index_frequency_minutes}
          aria-current={if minutes == @source.index_frequency_minutes, do: "true"}
          class="gap-1.5 px-2.5 disabled:cursor-default"
        >
          <.icon
            name="hero-check"
            class={"h-4 w-4 shrink-0 text-theme-primary #{if minutes != @source.index_frequency_minutes, do: "invisible"}"}
            aria-hidden="true"
          />
          {label}
        </button>
      </:option>
    </.button_dropdown>
    """
  end

  # Fast indexing fixes the full index at monthly, and individual videos are only indexed once.
  defp index_frequency_locked?(%{fast_index: true}), do: true
  defp index_frequency_locked?(%{collection_type: :video}), do: true
  defp index_frequency_locked?(_source), do: false

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
      aria_label={"#{@source.media_profile.name}, change the media profile for #{@source.custom_name}"}
      tooltip="Change Media Profile"
      tooltip_position="top"
      align="start"
      class="w-fit"
    >
      <:trigger><span class={@text_class}>{@source.media_profile.name}</span></:trigger>
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

  defp parse_retention_days(days) do
    case String.trim(days) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {days, ""} when days >= 0 -> {:ok, days}
          _invalid -> :error
        end
    end
  end

  defp bulk_jobs, do: for({job, label} <- SourceActions.jobs(), do: {to_string(job), job, label})

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
    search_term = normalize_search_term(session["initial_search_term"])

    initial_params =
      Map.merge(
        %{
          sort_key: session["initial_sort_key"],
          source_type: source_type,
          return_to: if(source_type == :videos, do: ~p"/sources?type=videos", else: ~p"/sources"),
          sort_direction: session["initial_sort_direction"],
          view_mode: normalize_view_mode(session["initial_view_mode"]),
          grid_sort: {session["initial_sort_key"], session["initial_sort_direction"]},
          search_term: search_term,
          refresh_pending: false,
          selected_ids: MapSet.new(),
          selection_scope: :page,
          notice: nil,
          armed: nil,
          done_action: nil,
          delete_ids: [],
          delete_names: [],
          job_running: nil,
          notice_id: 0,
          downloading_ids: MapSet.new(),
          media_profiles: Enum.reject(Profiles.list_media_profiles(), & &1.marked_for_deletion_at),
          timezone: Application.fetch_env!(:pinchflat, :timezone)
        },
        search_pagination_attributes(source_type, search_term, 1, limit)
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
    |> assign(search_pagination_attributes(assigns.source_type, assigns.search_term, new_page, assigns.limit))
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

  def handle_event("search", params, socket) do
    {:noreply, apply_search(socket, normalize_search_term(params["q"]))}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, apply_search(socket, nil)}
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

  def handle_event("set_source_retention", %{"source_id" => id, "retention_period_days" => days}, socket) do
    with %{} <- Enum.find(socket.assigns.sources, &(to_string(&1.id) == id)),
         {:ok, days} <- parse_retention_days(days),
         {:ok, _source} <- id |> Sources.get_source!() |> Sources.update_source(%{"retention_period_days" => days}) do
      {:noreply, set_sources(socket)}
    else
      _error ->
        notice = {:error, "Could not change the retention. Enter a whole number of days, 0 or more, or leave it blank."}
        {:noreply, socket |> put_notice(notice) |> set_sources()}
    end
  end

  def handle_event("set_source_index_frequency", %{"id" => id, "minutes" => minutes}, socket) do
    allowed = Enum.map(SourceHTML.friendly_index_frequencies(), fn {_label, value} -> to_string(value) end)
    source = Enum.find(socket.assigns.sources, &(to_string(&1.id) == id))

    with true <- minutes in allowed,
         %{} <- source,
         false <- index_frequency_locked?(source),
         {:ok, _source} <-
           id |> Sources.get_source!() |> Sources.update_source(%{"index_frequency_minutes" => minutes}) do
      {:noreply, set_sources(socket)}
    else
      _error ->
        notice = {:error, "Could not change the index frequency. Reload the page and try again."}
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
    case {List.keyfind(bulk_jobs(), name, 0), socket.assigns.job_running} do
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
    {:noreply, assign_delete(socket, ids)}
  end

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign_delete(socket, Enum.sort(socket.assigns.selected_ids))}
  end

  # Cancelling empties the dialog, so it can't post an earlier choice if the next open
  # doesn't reach the server.
  def handle_event("cancel_delete", _params, socket), do: {:noreply, assign_delete(socket, [])}

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

  def handle_info({:disarm_bulk, ref}, %{assigns: %{armed: {_action, _ids, ref, _ripe}}} = socket) do
    {:noreply, assign(socket, :armed, nil)}
  end

  def handle_info({:disarm_bulk, _ref}, socket), do: {:noreply, socket}

  def handle_info({:ripen_bulk, ref}, %{assigns: %{armed: {action, ids, ref, false}}} = socket) do
    {:noreply, assign(socket, :armed, {action, ids, ref, true})}
  end

  def handle_info({:ripen_bulk, _ref}, socket), do: {:noreply, socket}

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

  # Most frequent first when ascending: fast indexing counts as its 10-minute check, and sources
  # indexed only once sort after every schedule.
  defp sort_attr(:index_frequency) do
    dynamic(
      [s],
      fragment(
        "CASE WHEN ? THEN 10 WHEN ? <= 0 THEN 2147483647 ELSE ? END",
        s.fast_index,
        s.index_frequency_minutes,
        s.index_frequency_minutes
      )
    )
  end

  # Shortest retention first when ascending, with retention off (no age-based cleanup) last.
  defp sort_attr(:retention) do
    dynamic(
      [s, mp],
      fragment(
        "CASE WHEN COALESCE(?, ?, 0) = 0 THEN 2147483647 ELSE COALESCE(?, ?, 0) END",
        s.retention_period_days,
        mp.retention_period_days,
        s.retention_period_days,
        mp.retention_period_days
      )
    )
  end

  defp sort_attr(:collection_type), do: dynamic([s], s.collection_type)

  defp apply_search(%{assigns: assigns} = socket, search_term) do
    socket
    |> assign(:search_term, search_term)
    |> assign(selected_ids: MapSet.new(), selection_scope: :page)
    |> assign(search_pagination_attributes(assigns.source_type, search_term, 1, assigns.limit))
    |> set_sources()
  end

  # While searching, the unfiltered total is counted too for the "Showing X of Y" summary.
  defp search_pagination_attributes(source_type, search_term, page, limit) do
    attributes = get_pagination_attributes(base_sources_query(source_type, search_term), page, limit)

    tab_record_count =
      if search_term,
        do: Repo.aggregate(base_sources_query(source_type, nil), :count, :id),
        else: attributes.total_record_count

    Map.put(attributes, :tab_record_count, tab_record_count)
  end

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
        sources_query(assigns.source_type, assigns.search_term, nil)
        |> order_by(^order)
        |> limit(^assigns.limit)
        |> offset(^assigns.offset)
        |> Repo.all()
      else
        page_ids =
          base_sources_query(assigns.source_type, assigns.search_term)
          |> order_by(^order)
          |> limit(^assigns.limit)
          |> offset(^assigns.offset)
          |> select([s], s.id)
          |> Repo.all()

        sources_query(assigns.source_type, assigns.search_term, page_ids)
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

      match?({^action, ^ids, _ref, true}, assigns.armed) ->
        run_bulk_action(assign(socket, :armed, nil), action, ids)

      armed?(assigns.armed, action, ids) ->
        {:noreply, socket}

      true ->
        ref = make_ref()
        Process.send_after(self(), {:ripen_bulk, ref}, @bulk_ripen_ms)
        Process.send_after(self(), {:disarm_bulk, ref}, @bulk_arm_ms)
        {:noreply, assign(socket, :armed, {action, ids, ref, false})}
    end
  end

  defp armed?({action, ids, _ref, _ripe}, action, ids), do: true
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

  defp assign_delete(socket, ids) do
    names =
      from(s in Source,
        where: s.id in ^Enum.map(ids, &String.to_integer/1),
        order_by: s.custom_name,
        select: s.custom_name
      )
      |> Repo.all()

    assign(socket, delete_ids: ids, delete_names: names)
  end

  defp put_notice(socket, notice), do: assign(socket, notice: notice, notice_id: socket.assigns.notice_id + 1)

  defp bulk_job_message(job, summary) do
    label = SourceActions.label(job)
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

  # Selects every source in the tab (or the search results). Past the bulk action limit it
  # selects the page instead, and the selection banner explains why.
  defp select_all(%{assigns: assigns} = socket) do
    if assigns.total_record_count <= Sources.selection_limit() do
      ids =
        base_sources_query(assigns.source_type, assigns.search_term)
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

  defp base_sources_query(source_type, search_term) do
    from s in Source,
      as: :source,
      inner_join: mp in assoc(s, :media_profile),
      where: ^source_type_filter(source_type),
      where: ^search_filter(search_term),
      where: is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at)
  end

  # `source_ids` limits the media totals to the sources on the current page; nil totals every source.
  defp sources_query(source_type, search_term, source_ids) do
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

    from [s, mp] in base_sources_query(source_type, search_term),
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

  # LIKE wildcards in the term are escaped so they match literally.
  defp search_filter(nil), do: true

  defp search_filter(search_term) do
    pattern = "%" <> escape_like_pattern(String.downcase(search_term)) <> "%"

    dynamic(
      [s],
      fragment("LOWER(?) LIKE ? ESCAPE '\\'", s.custom_name, ^pattern) or
        fragment("LOWER(?) LIKE ? ESCAPE '\\'", s.collection_name, ^pattern)
    )
  end

  defp escape_like_pattern(term), do: String.replace(term, ["\\", "%", "_"], &("\\" <> &1))

  defp source_type_filter(:videos), do: dynamic([s], s.collection_type == :video)
  defp source_type_filter(:channels), do: dynamic([s], is_nil(s.collection_type) or s.collection_type != :video)
end
