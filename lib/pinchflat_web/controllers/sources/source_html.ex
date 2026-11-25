defmodule PinchflatWeb.Sources.SourceHTML do
  use PinchflatWeb, :html

  import PinchflatWeb.CustomComponents.DatePicker, only: [date_picker: 1]

  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Sources
  alias Pinchflat.Sources.CustomPoster
  alias Pinchflat.Sources.Source
  alias PinchflatWeb.MediaProfiles.MediaProfileHTML

  embed_templates "source_html/*"

  @source_switches [
    {:start, "hero-play-solid", "Start All"},
    {:pause, "hero-pause-solid", "Pause All"},
    {:stop, "hero-stop-solid", "Stop All"}
  ]

  @doc """
  Returns the Sources tab path, accepting only known local list destinations.
  """
  def source_list_path("/sources?type=videos"), do: ~p"/sources?type=videos"
  def source_list_path(_return_to), do: ~p"/sources"

  @doc """
  Hidden inputs that resubmit an edit from a confirmation page: the `source` params
  (list values become `source[key][]` inputs) plus any top-level `extra_params`,
  such as the yt-dlp options payload, exactly as they were submitted.
  """
  attr :source_params, :map, required: true
  attr :extra_params, :map, default: %{}

  def resubmitted_source_inputs(assigns) do
    ~H"""
    <%= for {key, value} <- @source_params do %>
      <input
        :for={item <- if(is_list(value), do: value, else: [value || ""])}
        type="hidden"
        name={if is_list(value), do: "source[#{key}][]", else: "source[#{key}]"}
        value={item}
      />
    <% end %>
    <input :for={{key, value} <- @extra_params} type="hidden" name={key} value={value} />
    """
  end

  @doc """
  Renders a source form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :media_profiles, :list, required: true
  attr :method, :string, required: true
  attr :current_path, :string, required: true
  attr :cookie_file_path, :string, required: true
  attr :cookie_file_exists, :boolean, required: true
  attr :cookie_file_configured, :boolean, required: true
  attr :cookie_file_contents, :string, default: nil
  attr :available_folders, :list, default: []
  attr :cutoff_downloaded_items, :list, default: []
  attr :show_delay_automatic_download, :boolean, default: false
  attr :new_source, :boolean, default: false
  attr :yt_dlp_options, :string, default: ""
  attr :yt_dlp_options_version, :any, default: :missing
  attr :yt_dlp_options_present, :boolean, default: false
  attr :yt_dlp_options_readable, :boolean, default: true
  attr :yt_dlp_options_clearable, :boolean, default: false
  attr :yt_dlp_options_inherited, :map, default: %{}
  attr :yt_dlp_options_profile_presence, :map, default: %{}
  attr :yt_dlp_error, :string, default: nil

  def source_form(assigns)

  @doc """
  Wraps a metadata-backed field (name or description) and manages its lock.
  Editing the field locks it so metadata refreshes keep the user's version;
  "Follow the channel again" clears the lock. The lock is submitted as a
  hidden boolean under the lock field's name.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :lock, Phoenix.HTML.FormField, required: true
  attr :noun, :string, required: true
  slot :inner_block, required: true

  def metadata_field_lock(assigns) do
    assigns = assign(assigns, :locked, Phoenix.HTML.Form.normalize_value("checkbox", assigns.lock.value))

    ~H"""
    <div id={"#{@field.id}-lock"} x-data={"{ locked: #{@locked} }"}>
      {render_slot(@inner_block)}
      <input type="hidden" name={@lock.name} value={to_string(@locked)} x-bind:value="locked ? 'true' : 'false'" />
      <p class="mt-1 flex flex-wrap items-center gap-x-3 text-sm text-theme-on-surface-muted">
        <span x-cloak x-show="!locked">Follows the channel: metadata refreshes update this {@noun}.</span>
        <span x-cloak x-show="locked">Kept as you set it: metadata refreshes leave this {@noun} alone.</span>
        <button
          type="button"
          x-cloak
          x-show="locked"
          class="min-h-11 font-medium text-theme-primary underline underline-offset-2 hover:text-theme-on-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70"
          x-on:click="locked = false; $nextTick(() => $root.querySelector('input:not([type=hidden]), textarea')?.focus())"
        >
          Follow the channel again
        </button>
      </p>
    </div>
    """
  end

  @doc """
  A source's collection type as an icon plus label, for places that list sources
  (the sources table, the source page). A source indexed before its type was
  known renders as "Unknown" rather than an empty cell.
  """
  attr :collection_type, :atom, required: true
  attr :class, :string, default: nil
  attr :label_class, :string, default: nil, doc: "classes for the label, such as hiding it visually when narrow"

  def collection_type_badge(assigns) do
    ~H"""
    <span
      class={["inline-flex items-center gap-1.5 whitespace-nowrap", @class]}
      title={collection_type_label(@collection_type) || "Unknown"}
    >
      <.icon name={collection_type_icon(@collection_type)} class="h-4 w-4 shrink-0 text-theme-on-surface-muted" />
      <span class={@label_class}>{collection_type_label(@collection_type) || "Unknown"}</span>
    </span>
    """
  end

  @doc """
  Display name for a `Source`'s `collection_type`. Nil when the type isn't known.
  """
  def collection_type_label(:channel), do: "Channel"
  def collection_type_label(:playlist), do: "Playlist"
  def collection_type_label(:video), do: "Video"
  def collection_type_label(_), do: nil

  @doc """
  Icon paired with a `collection_type` wherever it's displayed.
  """
  def collection_type_icon(:channel), do: "hero-tv"
  def collection_type_icon(:playlist), do: "hero-queue-list"
  def collection_type_icon(:video), do: "hero-play-circle"
  def collection_type_icon(_), do: "hero-question-mark-circle"

  @doc """
  Renders the compact media statistics summary shown on a source detail page.
  """
  attr :statistics, :map, required: true

  def source_statistics(assigns) do
    assigns =
      assign(assigns, :statistics_items, [
        {:downloaded, "Downloaded", "theme-status-success"},
        {:pending, "Pending", "theme-status-info"},
        {:failed, "Failed", "theme-status-error"},
        {:prevented, "Prevented", "theme-status-warning"},
        {:unavailable, "Skipped", "text-theme-on-surface-muted"}
      ])

    ~H"""
    <section
      id="source-media-statistics"
      aria-labelledby="source-media-statistics-title"
      class="theme-surface-accent mb-6 rounded-m3-lg px-4 py-3 sm:px-5"
    >
      <h3 id="source-media-statistics-title" class="sr-only">Source media statistics</h3>
      <dl class="grid grid-cols-2 divide-x divide-y divide-theme-outline/50 sm:grid-cols-5 sm:divide-y-0">
        <div
          :for={{key, label, value_class} <- @statistics_items}
          class={[
            "flex min-w-0 flex-col gap-1 px-3 py-2 first:pl-0 last:pr-0 sm:px-4",
            key == :unavailable && "col-span-2 sm:col-span-1"
          ]}
        >
          <dt class="truncate text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted">{label}</dt>
          <dd
            class={["text-xl font-semibold tabular-nums", value_class]}
            aria-label={"#{if(key == :unavailable, do: "Unavailable / Skipped", else: label)}: #{Map.fetch!(@statistics, key)}"}
          >
            <.localized_number number={Map.fetch!(@statistics, key)} />
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  @doc """
  Describes a source's status.

  A disabled source always shows as disabled. An enabled source shows as
  downloading while it has download jobs running or queued, otherwise its
  bolt is green with Download Media on and purple with it off.

  Returns a map with `:label`, `:icon`, `:pill_class` (the bordered pill on a
  source's page) and `:switch_class` (the enable switch in the sources list).
  """
  def source_status(%{enabled: false}, _downloading?),
    do: %{
      label: "Disabled",
      icon: "hero-pause",
      pill_class: "theme-pill-warning",
      switch_class: "theme-status-switch-neutral"
    }

  def source_status(_source, true),
    do: %{
      label: "Downloading",
      icon: "hero-clock",
      pill_class: "theme-pill-warning",
      switch_class: "theme-status-switch-warning theme-status-switch-busy"
    }

  def source_status(%{download_media: false}, _downloading?),
    do: %{
      label: "Indexing Enabled, No Automatic Downloads",
      icon: "hero-bolt",
      pill_class: "theme-pill-info",
      switch_class: "theme-status-switch-info"
    }

  def source_status(_source, _downloading?),
    do: %{
      label: "Indexing Enabled, Automatically Downloads",
      icon: "hero-bolt",
      pill_class: "theme-pill-success",
      switch_class: "theme-status-switch-success"
    }

  @doc """
  The status as a labelled pill, shown on a source's page.
  """
  attr :source, :map, required: true
  attr :downloading, :boolean, required: true
  attr :id_prefix, :string, required: true

  def source_status_pill(assigns) do
    assigns = assign(assigns, :status, source_status(assigns.source, assigns.downloading))

    ~H"""
    <span
      id={"source-status-#{@id_prefix}-#{@source.id}"}
      class={["theme-pill", @status.pill_class]}
      data-source-status={@status.label}
    >
      <.icon name={@status.icon} class="h-3.5 w-3.5" aria-hidden="true" />
      {@status.label}
    </span>
    """
  end

  @doc """
  The status as a switch for the sources list. The status icon is the knob, which sits right
  while the source is enabled, and clicking it enables or disables the source. While the source
  downloads, a light runs around the border.
  """
  attr :source, :map, required: true
  attr :downloading, :boolean, required: true
  attr :id_prefix, :string, required: true
  attr :tooltip_position, :string, default: "top"

  def source_status_switch(assigns) do
    status = source_status(assigns.source, assigns.downloading)
    action = if assigns.source.enabled, do: "disable", else: "enable"
    assigns = assign(assigns, status: status, action: action)

    ~H"""
    <.tooltip tooltip={@status.label} position={@tooltip_position} tooltip_class="text-center">
      <button
        type="button"
        id={"source-status-#{@id_prefix}-#{@source.id}"}
        role="switch"
        aria-checked={to_string(@source.enabled)}
        aria-label={"#{@status.label}. #{String.capitalize(@action)} #{@source.custom_name}"}
        data-source-status={@status.label}
        class={["theme-status-switch", @status.switch_class]}
        phx-click="toggle_source_enabled"
        phx-value-id={@source.id}
      >
        <span class="theme-status-switch-knob">
          <.icon :if={@status.icon == "hero-bolt"} name="hero-bolt-solid" class="h-4.5 w-4.5" aria-hidden="true" />
          <.icon :if={@status.icon != "hero-bolt"} name={@status.icon} class="h-4 w-4" aria-hidden="true" />
        </span>
      </button>
    </.tooltip>
    """
  end

  @doc """
  The cutoff being applied on the bulk cutoff confirmation page.
  """
  def bulk_cutoff_label(%{rolling_days: days}) when is_integer(days), do: "the last #{days} days"
  def bulk_cutoff_label(%{cutoff: %Date{} = cutoff}), do: Date.to_iso8601(cutoff)
  def bulk_cutoff_label(_preview), do: "No cutoff"

  @doc """
  A source's current download cutoff for the bulk cutoff confirmation page.
  """
  def source_cutoff_label(%{download_cutoff_date: %Date{} = date}), do: Date.to_iso8601(date)
  def source_cutoff_label(%{download_cutoff_days: days}) when is_integer(days) and days > 0, do: "last #{days} days"
  def source_cutoff_label(_source), do: "No cutoff"

  @doc """
  The source actions menu, shared by a source's page and the sources list. Actions run on the
  first click. Download Pending only appears when items are pending. Redownload Existing is always
  listed, and both are disabled with the reason while automatic downloads are off or Redownload
  Existing has nothing downloaded to act on. Start
  All, Pause All and Stop All share one Downloads row of icon buttons, each greyed out when it
  would do nothing: Start All without pending items, Pause All and Stop All without downloads
  running or queued.
  """
  attr :source, :map, required: true
  attr :pending_count, :integer, required: true
  attr :downloaded_count, :integer, required: true
  attr :json, :string, default: nil, doc: "the source as JSON, which adds Copy JSON"
  attr :show_feed, :boolean, default: true, doc: "lists Copy RSS Feed"
  attr :downloading, :boolean, default: false, doc: "whether the source has downloads running or queued"

  attr :live, :boolean,
    default: false,
    doc: "run actions as LiveView events on the sources list, which reports them without reloading the page"

  attr :return_to, :string, default: nil, doc: "a source list path to return to; actions otherwise stay on the source"
  attr :text, :string, default: nil
  attr :icon_name, :string, default: nil
  attr :aria_label, :string, default: nil
  attr :tooltip, :string, default: nil
  attr :tooltip_position, :string, default: "bottom"
  attr :edit_path, :string, default: nil, doc: "adds Edit to the menu"
  attr :on_delete, :any, default: nil, doc: "a JS command for a Delete option"
  attr :row_option_class, :string, default: nil, doc: "classes for Edit and Delete, to show them only when needed"

  def source_actions_menu(assigns) do
    assigns =
      assigns
      |> assign(:jobs, source_jobs(assigns))
      |> assign(:switches, source_switches(assigns))
      |> assign(:feed_path, ~p"/sources/#{assigns.source.uuid}/feed" <> ".xml")

    ~H"""
    <.button_dropdown
      text={@text}
      icon_name={@icon_name}
      aria_label={@aria_label}
      tooltip={@tooltip}
      tooltip_position={@tooltip_position}
      variant="outline"
      size="compact"
      class="shrink-0"
    >
      <:option :if={@edit_path}>
        <.link href={@edit_path} class={@row_option_class}>Edit</.link>
      </:option>
      <:option :if={@on_delete}>
        <button
          type="button"
          class={["text-theme-error!", @row_option_class]}
          x-on:click="dropdownOpen = false"
          phx-click={@on_delete}
        >
          Delete
        </button>
      </:option>
      <:option :if={@edit_path || @on_delete}>
        <div class={["h-px w-full bg-theme-outline/70", @row_option_class]}></div>
      </:option>

      <:option :if={@show_feed}>
        <.link
          href={@feed_path}
          x-data="{ copied: false }"
          x-on:click={"$event.preventDefault(); copyWithCallbacks(new URL('#{@feed_path}', location.origin).href, () => copied = true, () => copied = false)"}
        >
          Copy RSS Feed
          <span x-show="copied" x-cloak x-transition.duration.150ms><.icon name="hero-check" class="h-4 w-4" /></span>
        </.link>
      </:option>

      <:option :if={@json}>
        <button
          type="button"
          x-data="{ copied: false }"
          data-json={@json}
          x-on:click="copyWithCallbacks($el.dataset.json, () => copied = true, () => copied = false)"
        >
          Copy JSON
          <span x-show="copied" x-cloak x-transition.duration.150ms><.icon name="hero-check" class="h-4 w-4" /></span>
        </button>
      </:option>

      <:option><.link href={~p"/sources/new?template_id=#{@source.id}"}>Use as Template</.link></:option>
      <:option>
        <div class="h-px w-full bg-theme-outline/70"></div>
      </:option>

      <:option :for={{job, label, unavailable} <- @jobs}>
        <.action_form
          :if={!unavailable}
          action={source_action_path(@source, job)}
          return_to={@return_to}
          event={@live && "source_job"}
          values={%{id: @source.id, action: job}}
        >
          {label}
        </.action_form>
        <button
          :if={unavailable}
          type="button"
          disabled
          class="flex-col items-start! gap-0! disabled:cursor-not-allowed disabled:opacity-60"
        >
          {label} <span class="text-xs font-normal">{unavailable}</span>
        </button>
      </:option>

      <:option><.link href={~p"/reconciliation?source_id=#{@source.id}"}>Reconcile Files</.link></:option>
      <:option>
        <div class="h-px w-full bg-theme-outline/70"></div>
      </:option>

      <:option>
        <.action_form
          action={~p"/sources/#{@source.id}/automatic_downloads?#{[enabled: !@source.download_media]}"}
          return_to={@return_to}
          event={@live && "source_automatic_downloads"}
          values={%{id: @source.id, enabled: to_string(!@source.download_media)}}
        >
          <.icon name={if @source.download_media, do: "hero-bolt-slash-solid", else: "hero-bolt-solid"} class="h-4 w-4" />
          {if @source.download_media, do: "Disable Automatic Downloads", else: "Enable Automatic Downloads"}
        </.action_form>
      </:option>

      <:option>
        <div class="flex min-h-11 items-center justify-between gap-3 px-4 text-sm font-medium text-theme-on-surface-muted">
          <span>Downloads</span>
          <div class="flex items-center gap-1">
            <.tooltip
              :for={{switch, icon, label, idle} <- @switches}
              tooltip={if idle, do: "#{label}: #{idle}", else: label}
              position="top"
              tooltip_class="text-nowrap"
            >
              <.action_form
                action={source_action_path(@source, switch)}
                return_to={@return_to}
                event={@live && "source_switch"}
                values={%{id: @source.id, action: switch}}
                disabled={!!idle}
                aria_label={"#{label}: #{@source.custom_name}"}
                button_class="theme-field-action h-9 w-9 disabled:pointer-events-none disabled:opacity-40 max-sm:h-11 max-sm:w-11"
              >
                <.icon name={icon} class="h-4 w-4" />
              </.action_form>
            </.tooltip>
          </div>
        </div>
      </:option>
    </.button_dropdown>
    """
  end

  @doc """
  The delete confirmation shared by a source's page and the sources list. It names the sources
  and offers keeping or deleting the downloaded files.
  """
  attr :id, :string, required: true
  attr :form_id, :string, default: nil
  attr :names, :list, required: true, doc: "the custom names of the sources being deleted"
  attr :action, :string, required: true
  attr :method, :string, default: "post"
  attr :return_to, :string, default: nil
  attr :source_ids, :list, default: []
  attr :on_cancel, JS, default: %JS{}

  def source_delete_dialog(assigns) do
    assigns =
      assigns
      |> assign(:count, length(assigns.names))
      |> assign(:listed, Enum.take(assigns.names, 5))

    ~H"""
    <.modal id={@id} compact on_cancel={@on_cancel}>
      <h3 id={"#{@id}-title"} class="pr-8 text-lg font-semibold text-theme-on-surface">
        {case @names do
          [name] -> "Delete #{name}?"
          _names -> "Delete #{@count} sources?"
        end}
      </h3>
      <ul :if={@count > 1} id={"#{@id}-names"} class="mt-2 list-disc pl-5 text-sm text-theme-on-surface">
        <li :for={name <- @listed} class="truncate">{name}</li>
        <li :if={@count > length(@listed)}>and {@count - length(@listed)} more</li>
      </ul>
      <p id={"#{@id}-description"} class="mt-2 text-sm text-theme-on-surface-muted">
        Indexing and downloads stop. Choose whether to keep the downloaded files. This can't be undone.
      </p>
      <.form
        for={%{}}
        id={@form_id}
        action={@action}
        method={@method}
        class="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end"
      >
        <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
        <input :for={id <- @source_ids} type="hidden" name="source_ids[]" value={id} />
        <.button type="button" variant="outline" size="compact" phx-click={JS.exec("data-cancel", to: "##{@id}")}>
          Cancel
        </.button>
        <.button type="submit" variant="danger" size="compact" disabled={@count == 0}>
          {if @count == 1, do: "Delete Source", else: "Delete Sources"}
        </.button>
        <.button
          type="submit"
          variant="danger-solid"
          size="compact"
          name="delete_files"
          value="true"
          disabled={@count == 0}
        >
          {if @count == 1, do: "Delete Source + Files", else: "Delete Sources + Files"}
        </.button>
      </.form>
    </.modal>
    """
  end

  @doc """
  Library-style source header: artwork, collection type, status, compact URL,
  next index time, and description.
  """
  attr :source, :any, required: true
  attr :status, :atom, required: true
  attr :downloading, :boolean, default: false
  attr :pending_tasks, :list, required: true

  def source_library_header(assigns) do
    assigns =
      assigns
      |> assign(:next_check, next_check_at(assigns.pending_tasks))
      |> assign(:has_poster, source_image?(assigns.source, :poster))
      |> assign(:url_label, source_url_label(assigns.source.original_url))

    ~H"""
    <section id="source-library-header" class="theme-surface-accent mb-6 rounded-m3-lg px-5 py-5 sm:px-6">
      <div class="flex flex-col gap-5 sm:flex-row sm:items-start">
        <div class="relative h-28 w-28 shrink-0 overflow-hidden rounded-m3-md bg-theme-surface-4 sm:h-32 sm:w-32">
          <img
            :if={@has_poster}
            src={poster_preview_url(@source)}
            alt={"Artwork for #{@source.custom_name}"}
            class="h-full w-full object-cover"
          />
          <div
            :if={!@has_poster}
            class="flex h-full w-full flex-col items-center justify-center gap-1 bg-theme-primary-container/30 text-theme-on-primary-container"
          >
            <span class="text-2xl font-bold">{source_initials(@source)}</span>
          </div>
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <.source_status_pill source={@source} downloading={@downloading} id_prefix="header" />
            <span :if={@status == :error} class="theme-pill theme-pill-error">
              <.icon name="hero-exclamation-triangle" class="h-3.5 w-3.5" /> Error
            </span>
          </div>

          <div class="mt-2 flex flex-col items-start gap-1.5 text-sm text-theme-on-surface-muted">
            <div class="flex min-w-0 max-w-full flex-wrap items-center gap-2">
              <.collection_type_badge collection_type={@source.collection_type} />
              <a
                :if={@source.original_url}
                href={@source.original_url}
                target="_blank"
                rel="noopener noreferrer"
                title={@source.original_url}
                class="min-w-0 break-all text-theme-primary hover:underline"
              >
                {@url_label}
              </a>
            </div>
            <span :if={@next_check == :now}>Next check: checking now</span>
            <span :if={match?(%DateTime{}, @next_check)}>
              Next check: <.datetime_in_zone datetime={@next_check} format="%Y-%m-%d %H:%M" />
            </span>
            <p :if={@source.description} class="whitespace-pre-line text-left">{String.trim(@source.description)}</p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Grouped source settings, replacing the raw attribute dump. Unset fields stay
  hidden until the user asks for them.
  """
  attr :source, :any, required: true

  def source_info_panel(assigns) do
    assigns =
      assigns
      |> assign(:groups, info_groups(assigns.source))
      |> assign(:internal_fields, internal_fields(assigns.source))

    ~H"""
    <div id="source-info-panel" class="flex flex-col gap-4 text-theme-on-surface">
      <section :for={group <- @groups} class="theme-surface-accent rounded-m3-md px-5 py-3">
        <h3
          class="flex items-center gap-2 text-lg font-semibold leading-none"
          x-bind:class={"showUnset || #{group.any_set?} ? 'mb-3' : ''"}
        >
          <.icon name={group.icon} class="h-5 w-5 text-theme-on-surface-muted" />
          {group.title}
        </h3>

        <dl
          class="divide-y divide-theme-outline/50"
          x-show={"showUnset || #{group.any_set?}"}
          x-cloak={unless group.any_set?, do: true}
        >
          <div
            :for={field <- group.fields}
            class="grid gap-1 py-3 sm:grid-cols-[12rem_minmax(0,1fr)] sm:gap-4"
            x-show={if(field_set?(field), do: "true", else: "showUnset")}
            x-cloak={unless field_set?(field), do: true}
          >
            <dt class="text-sm font-medium text-theme-on-surface-muted">
              <.tooltip :if={field.tooltip} tooltip={field.tooltip} position="bottom">
                <span>{field.label}</span>
              </.tooltip>
              <span :if={!field.tooltip}>{field.label}</span>
            </dt>
            <dd class="min-w-0 text-sm">
              <.source_info_value field={field} />
              <p class="mt-1 text-xs text-theme-on-surface-muted">{field.help}</p>
            </dd>
          </div>
        </dl>
      </section>

      <details class="theme-surface-accent rounded-m3-md px-5 py-3">
        <summary class="flex min-h-6 cursor-pointer list-none items-center text-sm font-medium text-theme-on-surface-muted">
          Internal
        </summary>
        <dl class="mt-3 divide-y divide-theme-outline/50">
          <div :for={{label, value} <- @internal_fields} class="grid gap-1 py-2 sm:grid-cols-[12rem_minmax(0,1fr)] sm:gap-4">
            <dt class="text-sm text-theme-on-surface-muted">{label}</dt>
            <dd class="break-all font-mono text-xs text-theme-on-surface">{value || "—"}</dd>
          </div>
        </dl>
      </details>
    </div>
    """
  end

  attr :field, :map, required: true

  defp source_info_value(assigns) do
    field = assigns.field
    # Not field_set?/1: an inherited SponsorBlock label is shown even though the field is "unset".
    value = if is_binary(field.value) and String.trim(field.value) != "", do: field.value, else: "—"

    assigns = assign(assigns, :value, value)

    ~H"""
    <a
      :if={@field.href && field_set?(@field)}
      href={@field.href}
      target={if @field.type == :url, do: "_blank"}
      rel={if @field.type == :url, do: "noopener noreferrer"}
      class="text-theme-primary hover:underline"
    >
      <span class={info_value_class(@field.type)}>{@value}</span>
    </a>
    <span :if={!@field.href || !field_set?(@field)} class={info_value_class(@field.type)}>{@value}</span>
    """
  end

  defp info_value_class(type) when type in [:code, :long_code], do: "break-all font-mono text-xs"
  defp info_value_class(:long), do: "whitespace-pre-wrap"
  defp info_value_class(_type), do: "break-words"

  @doc """
  The "why is nothing downloading?" banner. Renders **only the first** blocking
  condition — the most fundamental one, since fixing it may well clear the rest —
  and renders nothing at all when the source is healthy. There is deliberately no
  green "all good" bar: no banner is the common case.
  """
  attr :source, :any, required: true
  attr :conditions, :list, required: true

  def blocking_banner(assigns) do
    condition = List.first(assigns.conditions)
    severity = condition && condition_severity(condition.code)

    assigns = assigns |> assign(:condition, condition) |> assign(:severity, severity)

    ~H"""
    <div
      :if={@condition}
      class={[
        "mb-6 flex flex-wrap items-center gap-x-4 gap-y-3 rounded-m3-sm border px-5 py-4",
        @severity == :danger && "border-theme-error bg-theme-error/10 text-theme-error",
        @severity == :warning && "border-theme-warning bg-theme-warning/10 text-theme-warning",
        @severity == :info && "border-theme-primary bg-theme-primary/10 text-theme-primary"
      ]}
    >
      <.icon name={severity_icon(@severity)} class="h-5 w-5 shrink-0" />
      <p class="min-w-0 grow text-sm">{@condition.message}</p>
      <% action = condition_action(@condition.code, @source) %>
      <.link
        :if={action}
        href={action.href}
        method={action.method}
        class="shrink-0 rounded-m3-xs border border-current px-3 py-1.5 text-sm font-medium hover:opacity-80"
      >
        {action.label}
      </.link>
    </div>
    """
  end

  defp severity_icon(:danger), do: "hero-x-circle"
  defp severity_icon(:info), do: "hero-information-circle"
  defp severity_icon(_warning), do: "hero-exclamation-triangle"

  # Something is actually broken.
  defp condition_severity(code) when code in [:indexing_failed, :storage_directory_unwritable], do: :danger
  # Working as intended and needs no action — just not obvious from an empty page.
  defp condition_severity(code) when code in [:index_pending, :queue_paused], do: :info
  # A setting the user chose that has a consequence they may not have intended.
  defp condition_severity(_code), do: :warning

  # The one control that resolves each condition. Routes live here rather than in
  # the `Sources` context, which has no business knowing about the router.
  defp condition_action(:downloads_disabled, source),
    do: %{label: "Edit source", href: ~p"/sources/#{source}/edit", method: "get"}

  defp condition_action(:never_indexed, source),
    do: %{label: "Check for new videos", href: ~p"/sources/#{source}/force_index", method: "post"}

  # An index is already on its way — the only thing to do is wait, so offering a
  # button would just enqueue a duplicate of the job that's already running
  defp condition_action(:index_pending, _source), do: nil

  defp condition_action(:index_found_nothing, source),
    do: %{label: "Edit source", href: ~p"/sources/#{source}/edit", method: "get"}

  defp condition_action(:all_filtered_out, source),
    do: %{label: "Review filters", href: ~p"/sources/#{source}/edit", method: "get"}

  defp condition_action(:cutoff_excludes_everything, source),
    do: %{label: "Change cutoff date", href: ~p"/sources/#{source}/edit", method: "get"}

  defp condition_action(:queue_paused, _source),
    do: %{label: "View diagnostics", href: ~p"/diagnostics", method: "get"}

  defp condition_action(:indexing_failed, _source),
    do: %{label: "View diagnostics", href: ~p"/diagnostics", method: "get"}

  # Permissions on the host volume — nothing in the app can fix this
  defp condition_action(:storage_directory_unwritable, _source), do: nil

  @doc """
  An activity entry's failure: the headline on screen, the rest behind a
  disclosure. Renders nothing when the entry didn't fail.
  """
  attr :error, :string, default: nil
  attr :id, :string, required: true

  def activity_error(assigns) do
    {headline, detail} = error_summary(assigns.error)

    assigns = assigns |> assign(:headline, headline) |> assign(:detail, detail)

    ~H"""
    <div :if={@headline} class="mt-2" x-data="{ open: false }">
      <p class="break-words text-sm theme-status-error">{@headline}</p>
      <button
        :if={@detail}
        type="button"
        x-on:click="open = !open"
        aria-controls={@id}
        class="mt-1 inline-flex items-center gap-1 text-xs text-theme-on-surface-muted hover:text-theme-on-surface"
      >
        <.icon name="hero-chevron-right" class="h-3 w-3 transition" x-bind:class="open && 'rotate-90'" />
        <span x-text="open ? 'Hide detail' : 'Show detail'">Show detail</span>
      </button>
      <pre
        :if={@detail}
        id={@id}
        x-show="open"
        x-cloak
        class="mt-2 max-h-64 overflow-auto rounded-xs bg-theme-surface-4 p-3 font-mono text-xs text-theme-on-surface"
      >{@detail}</pre>
    </div>
    """
  end

  @doc """
  One subscribable feed on the Podcast tab: what serves it, what that means, and
  the URL itself as a click-to-copy field. A feed that isn't available yet passes
  `url={nil}` and explains itself in the `:unavailable` slot instead.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, default: nil
  attr :url, :string, default: nil
  slot :description, required: true
  slot :unavailable

  def feed_option(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex flex-wrap items-center gap-2">
        <.icon name={@icon} class="h-5 w-5 text-theme-on-surface-muted" />
        <h4 class="font-semibold">{@title}</h4>
        <span
          :if={@badge}
          class="rounded-full bg-theme-surface-4 px-2 py-0.5 text-xs font-medium uppercase tracking-wide text-theme-on-surface-muted"
        >
          {@badge}
        </span>
      </div>
      <p class="mt-1 max-w-prose text-sm text-theme-on-surface-muted">{render_slot(@description)}</p>

      <div
        :if={@url}
        class="mt-3 flex items-center gap-2 rounded-md border border-theme-outline bg-theme-surface-1 px-3 py-2"
        x-data="{ copied: false }"
        x-on:click={~s"
          copyWithCallbacks(
            '#{@url}',
            () => copied = true,
            () => copied = false
          )
        "}
        title="Click to copy"
        role="button"
      >
        <code class="min-w-0 grow cursor-pointer break-all font-mono text-xs">{@url}</code>
        <span class="shrink-0 text-theme-on-surface-muted">
          <.icon x-show="!copied" name="hero-clipboard-document" class="h-4 w-4" />
          <.icon x-show="copied" x-cloak name="hero-check" class="h-4 w-4 theme-status-success" />
        </span>
      </div>

      <div
        :if={!@url && @unavailable != []}
        class="mt-3 rounded-md border border-theme-warning/40 bg-theme-warning/5 px-3 py-2"
      >
        <p class="max-w-prose text-sm theme-status-warning">{render_slot(@unavailable)}</p>
      </div>
    </div>
    """
  end

  @doc """
  A client-side-only switch bound to an Alpine boolean, styled to match the
  form toggle in `CoreComponents.input/1`. Unlike that one
  this has no form field behind it — the real checkbox is visually hidden and
  drives the Alpine state, which keeps the label clickable and the control
  reachable by keyboard.
  """
  attr :model, :string, required: true, doc: "the Alpine expression to bind (e.g. \"showUnset\")"
  attr :label, :string, required: true

  def switch(assigns) do
    ~H"""
    <label class="group flex min-h-11 cursor-pointer select-none items-center gap-2.5 text-sm text-theme-on-surface-muted hover:text-theme-on-surface">
      <input type="checkbox" x-model={@model} class="peer sr-only" />
      <span class="theme-switch-target shrink-0 rounded-full peer-focus-visible:ring-2 peer-focus-visible:ring-theme-primary">
        <span
          class="theme-switch-track"
          x-bind:class={"#{@model} && 'border-theme-primary/70! bg-theme-primary-container!'"}
        ></span>
        <span
          class="theme-switch-thumb"
          x-bind:class={"#{@model} && 'translate-x-6 bg-theme-primary!'"}
        ></span>
      </span>
      {@label}
    </label>
    """
  end

  @doc """
  A compact two-or-more-option segmented control bound to an Alpine expression.
  Each option is a `{label, alpine_value}` pair — the value is written into the
  bound expression verbatim, so it must be a JS literal (`"true"`, `"'json'"`).
  """
  attr :model, :string, required: true
  attr :options, :list, required: true
  attr :aria_label, :string, default: nil

  def segmented_control(assigns) do
    ~H"""
    <div
      role="group"
      aria-label={@aria_label}
      class="inline-flex items-center gap-0.5 rounded-md border border-theme-outline p-0.5"
    >
      <button
        :for={{label, value} <- @options}
        type="button"
        x-on:click={"#{@model} = #{value}"}
        x-bind:class={"#{@model} === #{value} ? 'bg-theme-surface-4 text-theme-on-surface' : 'text-theme-on-surface-muted hover:text-theme-on-surface'"}
        x-bind:aria-pressed={"#{@model} === #{value}"}
        class="theme-filter-button rounded-m3-xs"
      >
        {label}
      </button>
    </div>
    """
  end

  @doc """
  Presentation attributes for one activity entry (a `Task` with its job and media
  item preloaded): what kind of work it is, how it's going, when it ran, and how
  long it took.

  Every value is already display-ready so the template does no formatting. The
  `error` is the most recent entry from the job's error list, present only for
  a job that has actually failed.
  """
  def activity_entry(task) do
    job = task.job

    %{
      id: task.id,
      label: worker_label(job.worker),
      icon: worker_icon(job.worker),
      target: task.media_item && (task.media_item.title || task.media_item.media_id),
      target_href: task.media_item && ~p"/sources/#{task.media_item.source_id}/media/#{task.media_item.id}",
      status: status_chip(job.state),
      occurred_at: job.completed_at || job.cancelled_at || job.discarded_at || job.attempted_at || job.scheduled_at,
      upcoming: job.state in ~w(available scheduled) and is_nil(job.attempted_at),
      duration: job_duration(job),
      attempts: job.attempt && job.attempt > 1 && "Attempt #{job.attempt} of #{job.max_attempts}",
      error: latest_error(job)
    }
  end

  # yt-dlp errors arrive as a formatted multi-line blob (often with a stacktrace).
  # The first line is the part worth putting on screen; the rest stays in the
  # expandable detail.
  @doc """
  Splits an error blob into its headline first line and the remaining detail
  (nil when there's nothing more to show).
  """
  def error_summary(nil), do: {nil, nil}

  def error_summary(error) do
    case String.split(error, "\n", parts: 2) do
      [headline] -> {String.trim(headline), nil}
      [headline, rest] -> {String.trim(headline), if(String.trim(rest) == "", do: nil, else: rest)}
    end
  end

  defp latest_error(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> List.last()
    |> case do
      %{"error" => error} when is_binary(error) -> error
      _ -> nil
    end
  end

  defp latest_error(_job), do: nil

  # Wall-clock time the job spent running. An executing job is still accruing, so
  # it's measured against now; a job that never started has no duration at all.
  defp job_duration(%{attempted_at: nil}), do: nil

  defp job_duration(%{attempted_at: started} = job) do
    finished = job.completed_at || job.cancelled_at || job.discarded_at

    ending =
      case {finished, job.state} do
        {nil, "executing"} -> DateTime.utc_now()
        {nil, _} -> nil
        {finished, _} -> finished
      end

    if ending, do: humanize_seconds(DateTime.diff(ending, started))
  end

  defp humanize_seconds(seconds) when seconds < 1, do: "under a second"
  defp humanize_seconds(seconds) when seconds < 60, do: "#{seconds}s"
  defp humanize_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp humanize_seconds(seconds), do: "#{div(seconds, 3600)}h #{seconds |> rem(3600) |> div(60)}m"

  defp status_chip("executing"),
    do: %{label: "Running", class: "bg-theme-primary/10 text-theme-primary", icon: "hero-arrow-path"}

  defp status_chip("completed"),
    do: %{label: "Completed", class: "bg-theme-success/10 text-theme-success", icon: "hero-check-circle"}

  defp status_chip("discarded"),
    do: %{label: "Failed", class: "bg-theme-error/10 text-theme-error", icon: "hero-x-circle"}

  defp status_chip("retryable"),
    do: %{label: "Retrying", class: "bg-theme-error/10 text-theme-error", icon: "hero-exclamation-triangle"}

  defp status_chip("cancelled"),
    do: %{label: "Cancelled", class: "bg-theme-surface-4 text-theme-on-surface-muted", icon: "hero-no-symbol"}

  defp status_chip(scheduled) when scheduled in ~w(available scheduled),
    do: %{label: "Scheduled", class: "bg-theme-surface-4 text-theme-on-surface-muted", icon: "hero-clock"}

  defp status_chip(state),
    do: %{label: String.capitalize(state), class: "bg-theme-surface-4 text-theme-on-surface-muted", icon: "hero-clock"}

  # Workers are full module names; only the last segment identifies the work.
  defp worker_basename(worker), do: worker |> to_string() |> String.split(".") |> List.last()

  defp worker_label(worker) do
    case worker_basename(worker) do
      "FastIndexingWorker" -> "Checked for new videos"
      "MediaCollectionIndexingWorker" -> "Indexed the collection"
      "MediaDownloadWorker" -> "Downloaded media"
      "MediaQualityUpgradeWorker" -> "Upgraded media quality"
      "MediaRetentionWorker" -> "Applied retention rules"
      "SourceMetadataStorageWorker" -> "Refreshed metadata and artwork"
      "FileSyncingWorker" -> "Checked files on disk"
      "PodcastExportWorker" -> "Exported the podcast feed"
      "PodcastSweepWorker" -> "Swept podcast feeds"
      "SourceDeletionWorker" -> "Deleted the source"
      "ReconcileWorker" -> "Reconciled files"
      other -> other |> String.replace_suffix("Worker", "") |> humanize_module()
    end
  end

  defp worker_icon(worker) do
    case worker_basename(worker) do
      "FastIndexingWorker" -> "hero-bolt"
      "MediaCollectionIndexingWorker" -> "hero-queue-list"
      "MediaDownloadWorker" -> "hero-arrow-down-tray"
      "MediaQualityUpgradeWorker" -> "hero-sparkles"
      "MediaRetentionWorker" -> "hero-trash"
      "SourceMetadataStorageWorker" -> "hero-document-text"
      "FileSyncingWorker" -> "hero-clipboard-document-check"
      worker when worker in ~w(PodcastExportWorker PodcastSweepWorker) -> "hero-microphone"
      "ReconcileWorker" -> "hero-arrows-right-left"
      _ -> "hero-cog-6-tooth"
    end
  end

  # "MediaCollectionIndexing" -> "Media collection indexing"
  defp humanize_module(name) do
    name
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.capitalize()
  end

  # Counts eligible-for-download media (`MediaQuery.pending/0`), not live jobs, so
  # the wording is "pending" rather than "queued" - see `Sources.tab_counts/1`.
  def download_pending_label(0), do: "Nothing pending right now"
  def download_pending_label(1), do: "1 pending video"
  def download_pending_label(count), do: "#{count} pending videos"

  def redownload_library_label(1), do: "Replace 1 existing file at current profile quality"
  def redownload_library_label(count), do: "Replace #{count} existing files at current profile quality"

  def friendly_index_frequencies do
    [
      {"Only once when first created", -1},
      {"30 minutes", 30},
      {"Hourly", 60},
      {"3 Hours", 3 * 60},
      {"6 Hours", 6 * 60},
      {"12 Hours", 12 * 60},
      {"Daily (recommended)", 24 * 60},
      {"Weekly", 7 * 24 * 60},
      {"Monthly", 30 * 24 * 60}
    ]
  end

  def friendly_cookie_behaviours do
    [
      {"Disabled", :disabled},
      {"When Needed", :when_needed},
      {"All Operations", :all_operations}
    ]
  end

  def friendly_player_clients do
    [{"Default", ""} | Pinchflat.Sources.Source.player_client_options()]
  end

  def cutoff_date_presets(now \\ DateTime.now!(Application.get_env(:pinchflat, :timezone))) do
    [
      {"7 days", compute_date_offset(now, 7)},
      {"14 days", compute_date_offset(now, 14)},
      {"30 days", compute_date_offset(now, 30)},
      {"60 days", compute_date_offset(now, 60)},
      {"90 days", compute_date_offset(now, 90)},
      {"180 days", compute_date_offset(now, 180)},
      {"365 days", compute_date_offset(now, 365)}
    ]
  end

  defp cutoff_form_mode(changeset) do
    cond do
      Ecto.Changeset.get_field(changeset, :download_cutoff_days) not in [nil, ""] -> "days"
      Ecto.Changeset.get_field(changeset, :download_cutoff_date) not in [nil, ""] -> "date"
      true -> "none"
    end
  end

  # UTC to match the queries and Source.effective_download_cutoff_date/2, so the preview
  # names the same date cleanup will use.
  defp cutoff_today_iso, do: Date.to_iso8601(Date.utc_today())

  @doc """
  The Settings tab's grouped view of a source, replacing the old raw attribute
  dump. Returns a list of `%{title, icon, fields}` groups, where each field is a
  `%{label, value, help, type, href, tooltip}` map. A field whose `value` is nil
  or blank is "unset" and hidden behind the panel's `Show unset fields` toggle —
  the template decides that via `field_set?/1` rather than dropping it here, so
  the toggle can reveal them without a round trip.

  Only user-meaningful fields live here. App-managed identifiers and filepaths
  are in `internal_fields/1`, in their own box below.
  """
  def info_groups(source) do
    [
      %{title: "Identity", icon: "hero-identification", fields: identity_fields(source)},
      %{title: "Indexing", icon: "hero-arrow-path", fields: indexing_fields(source)},
      %{title: "Filters", icon: "hero-funnel", fields: filter_fields(source)},
      %{title: "Storage", icon: "hero-folder", fields: storage_fields(source)}
    ]
    |> Enum.map(fn group ->
      Map.put(group, :any_set?, Enum.any?(group.fields, &field_set?/1))
    end)
  end

  defp identity_fields(source) do
    [
      field("Name", source.custom_name, "What this source is called throughout Pinchflat"),
      field("Collection name", source.collection_name, "The name reported by the channel or playlist itself"),
      field(
        "Type",
        collection_type_label(source.collection_type),
        "Whether this source is a channel, playlist, or single video. Set from the URL when the source was added"
      ),
      field(
        "Source URL",
        source_url_label(source.original_url),
        "The channel or playlist page Pinchflat-ngx indexes",
        type: :url,
        href: source.original_url
      ),
      field("Media profile", source.media_profile.name, "The download rules applied to this source's media",
        href: ~p"/media_profiles/#{source.media_profile_id}",
        tooltip: media_profile_summary(source.media_profile)
      ),
      field("Description", source.description, "The description reported by the source", type: :long)
    ]
  end

  defp indexing_fields(source) do
    [
      field(
        "Status",
        if(source.enabled, do: "Active", else: "Paused"),
        "A paused source is never indexed or downloaded"
      ),
      field("Download media", yes_no(source.download_media), "Whether newly indexed media is queued for download"),
      field(
        "Public and unlisted media",
        yes_no(source.download_public_media),
        "Whether public and unlisted media is eligible for download"
      ),
      field(
        "Members-only media",
        yes_no(source.download_members_only_media),
        "Whether subscriber-only, premium-only, and authentication-required media is eligible for download"
      ),
      field(
        "Index frequency",
        index_frequency_label(source.index_frequency_minutes),
        "How often the full channel or playlist is re-read"
      ),
      field("Fast indexing", yes_no(source.fast_index), "Checks the RSS feed every 10 minutes for brand-new uploads"),
      field(
        "Index cutoff date",
        format_date(source.index_cutoff_date),
        "Indexing stops once it reaches media published before this date"
      ),
      field(
        "Cookies",
        cookie_behaviour_label(source.cookie_behaviour),
        "When this source's requests use your cookies.txt file"
      ),
      field(
        "Player client",
        Pinchflat.Sources.Source.player_client_label(source.player_client),
        "The YouTube player client passed to yt-dlp, or Default when yt-dlp chooses"
      )
    ]
  end

  defp filter_fields(source) do
    playlist_fields =
      if source.collection_type == :playlist do
        [
          field(
            "Owner channel",
            source.owner_channel_id || "Unknown",
            "The channel that owns this playlist. Only owner uploads compares each video's uploader with it"
          ),
          field(
            "Only owner uploads",
            yes_no(source.only_owner_uploads),
            "Whether videos the owner added from other channels are listed but not downloaded"
          )
        ]
      else
        []
      end

    playlist_fields ++
      [
        field("Title filter", source.title_filter_regex, "Only media whose title matches this regex is downloaded",
          type: :code
        ),
        field(
          "Minimum duration",
          format_duration(source.min_duration_seconds),
          "Media shorter than this is skipped"
        ),
        field(
          "Maximum duration",
          format_duration(source.max_duration_seconds),
          "Media longer than this is skipped"
        ),
        field(
          "Download cutoff",
          download_cutoff_label(source),
          "Automatic downloads include this date. Cleanup deletes unprotected downloads from before it, even within retention"
        ),
        field(
          "SponsorBlock remove",
          sponsorblock_status_label(source, :remove),
          "Blank inherits the media profile, Off disables removal for this source, and custom categories replace the profile's list. Applies to future downloads, quality upgrades and redownloads; existing files are never re-cut",
          set?: source.sponsorblock_remove_categories != nil
        ),
        field(
          "SponsorBlock mark",
          sponsorblock_status_label(source, :mark),
          "Blank inherits the media profile, Off disables chapter marking for this source, and custom categories replace the profile's list. Applies to future downloads, quality upgrades and redownloads; existing files are never re-cut",
          set?: source.sponsorblock_mark_categories != nil
        )
      ]
  end

  defp storage_fields(source) do
    [
      field(
        "Output path template",
        source.output_path_template_override,
        "Overrides the media profile's template for this source only",
        type: :long_code
      ),
      field("Series directory", source.series_directory, "Where source-level artwork and NFO files are written",
        type: :code
      ),
      field(
        "Retention period",
        retention_policy_label(source),
        "Age is counted from download time. Blank inherits the profile; 0 disables age-based cleanup. Changing the profile can make older downloads eligible at next cleanup. Cutoff cleanup can delete files sooner based on publication date; protected media is excluded from both"
      ),
      field(
        "Keep newest",
        if(source.keep_newest_count, do: "Newest #{source.keep_newest_count}", else: nil),
        "Pinchflat keeps only the newest N downloaded or pending-eligible videos for this source. Older unprotected downloads are deleted at the next scheduled cleanup"
      )
    ]
  end

  @doc """
  App-managed identifiers and filepaths, shown as-is under the collapsed
  `Internal` disclosure. They're kept because they're the first thing anyone
  asks for during issue triage — they're just no longer the front door.
  """
  def internal_fields(source) do
    [
      {"ID", to_string(source.id)},
      {"UUID", source.uuid},
      {"Collection ID", source.collection_id},
      {"Download subdirectory", source.download_subdirectory},
      {"NFO filepath", source.nfo_filepath},
      {"Poster filepath", source.poster_filepath},
      {"Custom poster filename", source.custom_poster_filename},
      {"Fanart filepath", source.fanart_filepath},
      {"Banner filepath", source.banner_filepath},
      {"Marked for deletion at", source.marked_for_deletion_at && to_string(source.marked_for_deletion_at)},
      {"Created at", to_string(source.inserted_at)},
      {"Updated at", to_string(source.updated_at)}
    ]
  end

  @doc """
  Whether an `info_groups/1` field has a value worth showing. Unset fields are
  hidden until the user asks for them.
  """
  def field_set?(%{set?: set}) when is_boolean(set), do: set
  def field_set?(%{value: value}), do: is_binary(value) and String.trim(value) != ""

  @doc """
  Pretty-printed JSON for the source, the same payload as the `Copy JSON` action.
  """
  def source_json(source) do
    source
    |> Phoenix.json_library().encode!()
    |> Jason.Formatter.pretty_print()
  end

  # A one-line summary of the values people actually pick a profile for, shown on
  # hover next to the profile link so you don't have to open the profile page.
  defp media_profile_summary(media_profile) do
    resolution =
      case media_profile.preferred_resolution do
        :audio -> "Audio only"
        other -> to_string(other)
      end

    [
      resolution,
      media_profile.media_container && "#{media_profile.media_container} container",
      media_profile.download_subs && "subtitles",
      media_profile.download_thumbnail && "thumbnails",
      media_profile.download_nfo && "NFO",
      Pinchflat.Profiles.MediaProfile.podcast?(media_profile) && "podcast"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp field(label, value, help, opts \\ []) do
    %{
      label: label,
      value: value,
      help: help,
      type: Keyword.get(opts, :type, :text),
      href: Keyword.get(opts, :href),
      tooltip: Keyword.get(opts, :tooltip),
      set?: Keyword.get(opts, :set?)
    }
  end

  defp yes_no(true), do: "Yes"
  defp yes_no(_), do: "No"

  defp format_date(nil), do: nil
  defp format_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp download_cutoff_label(source) do
    cond do
      is_integer(source.download_cutoff_days) and source.download_cutoff_days > 0 ->
        effective = source |> Source.effective_download_cutoff_date() |> format_date()
        "Rolling #{source.download_cutoff_days} days (currently #{effective})"

      not is_nil(source.download_cutoff_date) ->
        format_date(source.download_cutoff_date)

      true ->
        nil
    end
  end

  defp format_duration(nil), do: nil

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = seconds |> rem(3600) |> div(60)
    secs = rem(seconds, 60)
    pad = &String.pad_leading(to_string(&1), 2, "0")

    if hours > 0 do
      "#{hours}:#{pad.(minutes)}:#{pad.(secs)}"
    else
      "#{minutes}:#{pad.(secs)}"
    end
  end

  @doc "The effective age-based cleanup policy, including where the setting comes from."
  def retention_policy_label(source) do
    case source.retention_period_days do
      nil ->
        case source.media_profile do
          %Pinchflat.Profiles.MediaProfile{retention_period_days: days} ->
            retention_days_label(days, "profile default")

          _ ->
            "Profile default (unavailable)"
        end

      days ->
        retention_days_label(days, "source override")
    end
  end

  def retention_form_preview(changeset, media_profiles) do
    profile_id = Ecto.Changeset.get_field(changeset, :media_profile_id)
    profile = Enum.find(media_profiles, &(to_string(&1.id) == to_string(profile_id)))

    retention_policy_label(%{
      retention_period_days: Ecto.Changeset.get_field(changeset, :retention_period_days),
      media_profile: profile
    })
  end

  defp retention_days_label(days, origin) when days in [nil, 0],
    do: "No age-based cleanup (#{origin})"

  defp retention_days_label(1, origin), do: "1 day (#{origin})"
  defp retention_days_label(days, origin), do: "#{days} days (#{origin})"

  @doc """
  Category labels for the SponsorBlock pickers, shared with the media profile form.
  """
  def friendly_sponsorblock_categories do
    MediaProfileHTML.friendly_sponsorblock_categories()
  end

  @sponsorblock_actions [:mark, :remove]

  @doc """
  The form mode for a SponsorBlock category field: `nil` inherits, `[]` disables,
  and anything else is a custom list.
  """
  def sponsorblock_mode(nil), do: "inherit"
  def sponsorblock_mode([]), do: "disable"
  def sponsorblock_mode(_categories), do: "custom"

  def sponsorblock_mode_options do
    [
      {"Inherit from the media profile", "inherit"},
      {"Off for this source", "disable"},
      {"Choose categories for this source", "custom"}
    ]
  end

  @doc """
  Each profile's effective SponsorBlock lists, keyed by profile id, so the form can
  preview what "Inherit" will use before saving.
  """
  def sponsorblock_profile_preview(media_profiles) do
    Map.new(media_profiles, fn profile ->
      {to_string(profile.id),
       %{
         "mark" => sponsorblock_categories_label(profile.sponsorblock_mark_categories),
         "remove" => sponsorblock_categories_label(profile.sponsorblock_remove_categories)
       }}
    end)
  end

  @doc """
  A short description of where a field's categories come from, for the form summary
  line and the source details panel.
  """
  def sponsorblock_status_label(changeset, media_profiles, action) do
    source = %Source{
      sponsorblock_mark_categories: Ecto.Changeset.get_field(changeset, :sponsorblock_mark_categories),
      sponsorblock_remove_categories: Ecto.Changeset.get_field(changeset, :sponsorblock_remove_categories)
    }

    sponsorblock_status_label_for(source, sponsorblock_profile_for(changeset, media_profiles), action)
  end

  @doc """
  A short description of a saved source's SponsorBlock override for the given action.
  """
  def sponsorblock_status_label(%Source{} = source, action) when action in @sponsorblock_actions do
    sponsorblock_status_label_for(source, source.media_profile, action)
  end

  defp sponsorblock_status_label_for(source, media_profile, action) do
    field = :"sponsorblock_#{action}_categories"

    case Map.fetch!(source, field) do
      nil ->
        inherited =
          case media_profile do
            %MediaProfile{} = profile -> Map.fetch!(profile, field)
            _ -> nil
          end

        "Inherit (#{sponsorblock_categories_label(inherited)})"

      [] ->
        "Off"

      categories ->
        "Custom (#{sponsorblock_categories_label(categories)})"
    end
  end

  defp sponsorblock_profile_for(changeset, media_profiles) do
    profile_id = Ecto.Changeset.get_field(changeset, :media_profile_id)
    Enum.find(media_profiles, &(to_string(&1.id) == to_string(profile_id)))
  end

  defp sponsorblock_categories_label(categories) when is_list(categories) do
    case Enum.reject(categories, &(&1 in [nil, ""])) do
      [] ->
        "none"

      categories ->
        friendly =
          MediaProfileHTML.friendly_sponsorblock_categories()
          |> Map.new(fn {label, value} -> {value, label} end)

        Enum.map_join(categories, ", ", &Map.get(friendly, &1, &1))
    end
  end

  defp sponsorblock_categories_label(_categories), do: "none"

  defp index_frequency_label(nil), do: nil

  defp index_frequency_label(minutes) do
    case Enum.find(friendly_index_frequencies(), fn {_label, value} -> value == minutes end) do
      {label, _value} -> label
      nil -> "Every #{minutes} minutes"
    end
  end

  defp cookie_behaviour_label(behaviour) do
    case Enum.find(friendly_cookie_behaviours(), fn {_label, value} -> value == behaviour end) do
      {label, _value} -> label
      nil -> behaviour && to_string(behaviour)
    end
  end

  @doc """
  Whether the source has the given on-disk artwork image (`:banner` or
  `:poster`), used to decide between a real `<img>` and the placeholder/initials
  fallback in the header. A single `File.exists?` per header render, not per row.
  """
  def source_image?(source, type) when type in [:banner, :poster] do
    file_present?(Sources.image_filepath(source, type))
  end

  defp file_present?(path), do: is_binary(path) and File.exists?(path)

  @doc """
  Whether the source has a saved custom poster file to manage from the edit page.
  """
  def custom_poster_present?(source) do
    file_present?(CustomPoster.filepath(source))
  end

  @doc """
  URL for the source poster preview, including a poster-specific cache version
  so a replacement is not hidden behind a browser or feed-reader cache.
  """
  def poster_preview_url(source) do
    extension =
      case Sources.image_filepath(source, :poster) do
        filepath when is_binary(filepath) -> Path.extname(filepath)
        _ -> ".jpg"
      end

    path = ~p"/sources/#{source.uuid}/feed_image"
    "#{path}#{extension}?v=#{CustomPoster.poster_cache_version(source)}"
  end

  @doc """
  Up to two uppercase initials derived from the source's display name, for the
  avatar fallback when no channel image is available.
  """
  def source_initials(source) do
    (source.custom_name || source.collection_name || "?")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  @doc """
  The soonest scheduled indexing run for the source (fast or slow indexing),
  derived from its already-loaded pending tasks.

  Returns a `DateTime`, `:now`, or nil when no indexing run is scheduled. `:now`
  covers the soonest run being due already — an `executing` job's `scheduled_at`
  is by definition in the past, and an overdue `available` one can be too, and
  neither should render as "Next check: 2 hours ago".
  """
  def next_check_at(pending_tasks) do
    pending_tasks
    |> Enum.filter(&String.ends_with?(&1.job.worker, "IndexingWorker"))
    |> Enum.map(& &1.job.scheduled_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        nil

      scheduled_ats ->
        soonest = Enum.min(scheduled_ats, DateTime)
        if DateTime.after?(soonest, DateTime.utc_now()), do: soonest, else: :now
    end
  end

  @doc """
  A compact, human-friendly label for a source's original URL. YouTube handle and
  channel URLs collapse to just the `@handle` (e.g.
  `https://www.youtube.com/@some-fake-channel` → `@some-fake-channel`), playlist
  URLs use `Open playlist on YouTube`, and anything else drops the scheme/`www.`
  and trailing slash. The value stays the link text — the `href` is still the
  full URL.
  """
  def source_url_label(url) when is_binary(url) do
    # The playlist ID is checked first: a playlist can live under a channel URL
    # (`/@someone/...?list=PL…`), where the list is what identifies the source.
    case {Regex.run(~r{[?&]list=([^&#]+)}, url), Regex.run(~r{/(@[^/?#]+)}, url)} do
      {[_, _playlist_id], _} -> "Open playlist on YouTube"
      {_, [_, handle]} -> handle
      _ -> url |> String.replace(~r{^https?://(www\.)?}, "") |> String.trim_trailing("/")
    end
  end

  def source_url_label(_), do: nil

  def rss_feed_url(conn, source) do
    # NOTE: The reason for this concatenation is to avoid what appears to be a bug in Phoenix
    # See: https://github.com/phoenixframework/phoenix/issues/6033
    url(conn, ~p"/sources/#{source.uuid}/feed") <> ".xml"
  end

  def opml_feed_url(conn) do
    url(conn, ~p"/sources/opml.xml?#{[route_token: Settings.get!(:route_token)]}")
  end

  def output_path_template_override_placeholders(media_profiles) do
    media_profiles
    |> Enum.map(&{&1.id, &1.output_path_template})
    |> Map.new()
    |> Phoenix.json_library().encode!()
  end

  # The word lists of the title filter builder, in the order they are shown
  def title_filter_groups do
    [
      %{
        key: "any",
        label: "Title contains ANY of",
        help: "At least one of these has to appear in the title.",
        placeholder: "tutorial, review, guide"
      },
      %{
        key: "all",
        label: "Title contains ALL of",
        help: "Every one of these has to appear in the title.",
        placeholder: "Season 2, 4K"
      },
      %{
        key: "none",
        label: "Title contains NONE of",
        help: "If the title has any of these, the video is skipped.",
        placeholder: "Trailer, Shorts, Livestream"
      }
    ]
  end

  # The saved regex as a JS string literal, to seed the title filter builder
  def title_filter_regex_json(form) do
    Phoenix.json_library().encode!(Phoenix.HTML.Form.normalize_value("text", form[:title_filter_regex].value) || "")
  end

  def title_filter_regex_help do
    url = "https://github.com/nalgeon/sqlean/blob/main/docs/regexp.md#supported-syntax"

    classes =
      "underline decoration-theme-on-surface-muted/70 decoration-1 hover:text-theme-on-surface hover:decoration-theme-on-surface"

    """
    A PCRE-compatible regex. Only media with titles that match this regex will be downloaded. <a href="#{url}" class="#{classes}" target="_blank">See here</a> for syntax
    """
  end

  def output_path_template_override_help do
    help_button_classes =
      "cursor-pointer underline decoration-theme-on-surface-muted/70 decoration-1 hover:text-theme-on-surface hover:decoration-theme-on-surface"

    help_button = ~s{<span class="#{help_button_classes}" x-on:click="$dispatch('load-template')">Click here</span>}

    """
    Must end with .{{ ext }}. Same rules as Media Profile output path templates. #{help_button} to load your media profile's output template
    """
  end

  def download_subdirectory_help do
    "Relative folder under the media root. Pinchflat-ngx applies this before the output template, so keep the template focused on filenames or subfolders inside this directory."
  end

  def download_subdirectory_examples do
    [
      "Kids/Bluey",
      "Podcasts/Tech",
      "TV/Documentaries"
    ]
  end

  defp compute_date_offset(now, days) do
    now
    |> DateTime.to_date()
    |> Date.add(-days)
    |> Date.to_iso8601()
  end

  attr :action, :string, required: true
  attr :return_to, :string, default: nil
  attr :event, :any, default: nil, doc: "a LiveView event to send instead of posting to the action"
  attr :values, :map, default: %{}, doc: "the event's values"
  attr :disabled, :boolean, default: false
  attr :aria_label, :string, default: nil
  attr :button_class, :string, default: nil
  slot :inner_block, required: true

  # A menu action that runs straight away. On a source's page it posts to the action, disabled
  # while it submits so a double click runs it once. On the sources list it sends a LiveView
  # event instead, so the list keeps its place and reports the result in a notice.
  defp action_form(%{event: event} = assigns) when is_binary(event) do
    assigns = assign(assigns, :phx_values, Enum.map(assigns.values, fn {key, value} -> {"phx-value-#{key}", value} end))

    ~H"""
    <button
      type="button"
      phx-click={@event}
      x-on:click="dropdownOpen = false"
      disabled={@disabled}
      aria-label={@aria_label}
      class={@button_class}
      {@phx_values}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp action_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      action={@action}
      method="post"
      class="w-full"
      x-data="{ submitting: false }"
      x-on:submit="submitting = true"
    >
      <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
      <button
        type="submit"
        x-bind:disabled={if @disabled, do: "true", else: "submitting"}
        disabled={@disabled}
        aria-label={@aria_label}
        class={@button_class}
      >
        {render_slot(@inner_block)}
      </button>
    </.form>
    """
  end

  defp source_switches(assigns) do
    for {switch, icon, label} <- @source_switches,
        do: {switch, icon, label, switch_idle_reason(switch, assigns.pending_count, assigns.downloading)}
  end

  defp switch_idle_reason(:start, 0, _downloading), do: "nothing pending"
  defp switch_idle_reason(switch, _pending, false) when switch in [:pause, :stop], do: "nothing downloading"
  defp switch_idle_reason(_switch, _pending, _downloading), do: nil

  defp source_jobs(assigns) do
    for {job, label} <- Pinchflat.Sources.SourceActions.jobs(),
        job != :download_pending or assigns.pending_count > 0,
        do: {job, label, source_job_unavailable(job, assigns)}
  end

  defp source_job_unavailable(job, %{source: %{download_media: false}})
       when job in [:download_pending, :redownload_existing],
       do: "Automatic downloads are off"

  defp source_job_unavailable(:redownload_existing, %{downloaded_count: 0}), do: "Nothing downloaded"
  defp source_job_unavailable(_job, _assigns), do: nil

  defp source_action_path(source, :download_pending), do: ~p"/sources/#{source.id}/force_download_pending"
  defp source_action_path(source, :redownload_existing), do: ~p"/sources/#{source.id}/force_redownload"
  defp source_action_path(source, :force_index), do: ~p"/sources/#{source.id}/force_index"
  defp source_action_path(source, :refresh_metadata), do: ~p"/sources/#{source.id}/force_metadata_refresh"
  defp source_action_path(source, :sync_files), do: ~p"/sources/#{source.id}/sync_files_on_disk"
  defp source_action_path(source, :start), do: ~p"/sources/#{source.id}/start_all"
  defp source_action_path(source, :pause), do: ~p"/sources/#{source.id}/pause_all"
  defp source_action_path(source, :stop), do: ~p"/sources/#{source.id}/stop_all"
end
