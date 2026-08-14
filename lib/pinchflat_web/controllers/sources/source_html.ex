defmodule PinchflatWeb.Sources.SourceHTML do
  use PinchflatWeb, :html

  embed_templates "source_html/*"

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
  attr :show_delay_automatic_download, :boolean, default: false

  def source_form(assigns)

  @doc """
  A source's collection type as an icon plus label, for places that list sources
  (the sources table, the source page). A source indexed before its type was
  known renders as "Unknown" rather than an empty cell.
  """
  attr :collection_type, :atom, required: true
  attr :class, :string, default: nil

  def collection_type_badge(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 whitespace-nowrap", @class]}>
      <.icon name={collection_type_icon(@collection_type)} class="h-4 w-4 shrink-0 text-theme-on-surface-muted" />
      {collection_type_label(@collection_type) || "Unknown"}
    </span>
    """
  end

  @doc """
  Display name for a `Source`'s `collection_type`. Nil when the type isn't known.
  """
  def collection_type_label(:channel), do: "Channel"
  def collection_type_label(:playlist), do: "Playlist"
  def collection_type_label(_), do: nil

  @doc """
  Icon paired with a `collection_type` wherever it's displayed.
  """
  def collection_type_icon(:channel), do: "hero-tv"
  def collection_type_icon(:playlist), do: "hero-queue-list"
  def collection_type_icon(_), do: "hero-question-mark-circle"

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
      <p class="min-w-0 grow max-w-prose text-sm">{@condition.message}</p>
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
      <p class="break-words text-sm text-danger">{@headline}</p>
      <button
        :if={@detail}
        type="button"
        x-on:click="open = !open"
        aria-controls={@id}
        class="mt-1 inline-flex items-center gap-1 text-xs text-bodydark hover:text-black dark:hover:text-white"
      >
        <.icon name="hero-chevron-right" class="h-3 w-3 transition" x-bind:class="open && 'rotate-90'" />
        <span x-text="open ? 'Hide detail' : 'Show detail'">Show detail</span>
      </button>
      <pre
        :if={@detail}
        id={@id}
        x-show="open"
        x-cloak
        class="mt-2 max-h-64 overflow-auto rounded-xs bg-meta-4 p-3 font-mono text-xs text-white"
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
        <.icon name={@icon} class="h-5 w-5 text-bodydark" />
        <h4 class="font-semibold">{@title}</h4>
        <span
          :if={@badge}
          class="rounded-full bg-meta-4 px-2 py-0.5 text-xs font-medium uppercase tracking-wide text-bodydark1"
        >
          {@badge}
        </span>
      </div>
      <p class="mt-1 max-w-prose text-sm text-bodydark">{render_slot(@description)}</p>

      <div
        :if={@url}
        class="mt-3 flex items-center gap-2 rounded-md border border-stroke bg-whiter px-3 py-2 dark:border-strokedark dark:bg-meta-4"
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
        <span class="shrink-0 text-bodydark">
          <.icon x-show="!copied" name="hero-clipboard-document" class="h-4 w-4" />
          <.icon x-show="copied" x-cloak name="hero-check" class="h-4 w-4 text-success" />
        </span>
      </div>

      <div :if={!@url && @unavailable != []} class="mt-3 rounded-md border border-warning/40 bg-warning/5 px-3 py-2">
        <p class="max-w-prose text-sm text-warning">{render_slot(@unavailable)}</p>
      </div>
    </div>
    """
  end

  @doc """
  A client-side-only switch bound to an Alpine boolean, styled to match the
  form toggle in `CoreComponents.input/1` at a smaller scale. Unlike that one
  this has no form field behind it — the real checkbox is visually hidden and
  drives the Alpine state, which keeps the label clickable and the control
  reachable by keyboard.
  """
  attr :model, :string, required: true, doc: "the Alpine expression to bind (e.g. \"showUnset\")"
  attr :label, :string, required: true

  def switch(assigns) do
    ~H"""
    <label class="group flex cursor-pointer select-none items-center gap-2.5 text-sm text-bodydark hover:text-black dark:hover:text-white">
      <input type="checkbox" x-model={@model} class="peer sr-only" />
      <span class="relative inline-block h-5 w-9 shrink-0">
        <span
          class="block h-full w-full rounded-full bg-stroke transition peer-focus-visible:ring-2 peer-focus-visible:ring-primary dark:bg-strokedark"
          x-bind:class={"#{@model} && 'bg-primary! dark:bg-primary!'"}
        ></span>
        <span
          class="absolute left-0.5 top-0.5 h-4 w-4 rounded-full bg-white shadow transition"
          x-bind:class={"#{@model} && 'translate-x-4'"}
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
      class="inline-flex items-center gap-0.5 rounded-md border border-stroke p-0.5 dark:border-strokedark"
    >
      <button
        :for={{label, value} <- @options}
        type="button"
        x-on:click={"#{@model} = #{value}"}
        x-bind:class={"#{@model} === #{value} ? 'bg-meta-4 text-white' : 'text-bodydark hover:text-black dark:hover:text-white'"}
        x-bind:aria-pressed={"#{@model} === #{value}"}
        class="rounded-sm px-2.5 py-1 text-xs font-medium transition"
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
    do: %{label: "Running", class: "bg-primary/10 text-primary", icon: "hero-arrow-path"}

  defp status_chip("completed"),
    do: %{label: "Completed", class: "bg-success/10 text-success", icon: "hero-check-circle"}

  defp status_chip("discarded"),
    do: %{label: "Failed", class: "bg-danger/10 text-danger", icon: "hero-x-circle"}

  defp status_chip("retryable"),
    do: %{label: "Retrying", class: "bg-danger/10 text-danger", icon: "hero-exclamation-triangle"}

  defp status_chip("cancelled"),
    do: %{label: "Cancelled", class: "bg-meta-4 text-bodydark1", icon: "hero-no-symbol"}

  defp status_chip(scheduled) when scheduled in ~w(available scheduled),
    do: %{label: "Scheduled", class: "bg-meta-4 text-bodydark1", icon: "hero-clock"}

  defp status_chip(state),
    do: %{label: String.capitalize(state), class: "bg-meta-4 text-bodydark1", icon: "hero-clock"}

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
      {"1 Hour", 60},
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

  def cutoff_date_presets do
    [
      {"7 days", compute_date_offset(7)},
      {"14 days", compute_date_offset(14)},
      {"30 days", compute_date_offset(30)},
      {"60 days", compute_date_offset(60)},
      {"90 days", compute_date_offset(90)},
      {"180 days", compute_date_offset(180)},
      {"365 days", compute_date_offset(365)}
    ]
  end

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
  end

  defp identity_fields(source) do
    [
      field("Name", source.custom_name, "What this source is called throughout Pinchflat"),
      field("Collection name", source.collection_name, "The name reported by the channel or playlist itself"),
      field(
        "Type",
        collection_type_label(source.collection_type),
        "Whether this source is a channel or a playlist. Set from the URL when the source was added"
      ),
      field(
        "Source URL",
        source_url_label(source.original_url),
        "The channel or playlist page Pinchflat indexes",
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
      )
    ]
  end

  defp filter_fields(source) do
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
        "Download cutoff date",
        format_date(source.download_cutoff_date),
        "Media published before this date is never downloaded"
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
        retention_label(source.retention_period_days),
        "Downloaded media older than this is deleted automatically"
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
      {"Slug", source.slug},
      {"NFO filepath", source.nfo_filepath},
      {"Poster filepath", source.poster_filepath},
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
      media_profile.podcast_enabled && "podcast"
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
      tooltip: Keyword.get(opts, :tooltip)
    }
  end

  defp yes_no(true), do: "Yes"
  defp yes_no(_), do: "No"

  defp format_date(nil), do: nil
  defp format_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

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

  defp retention_label(nil), do: nil
  defp retention_label(0), do: "Keep forever"
  defp retention_label(1), do: "1 day"
  defp retention_label(days), do: "#{days} days"

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
    file_present?(Pinchflat.Sources.image_filepath(source, type))
  end

  defp file_present?(path), do: is_binary(path) and File.exists?(path)

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
  Presentation attributes for the header status pill given `Sources.status/1`.
  """
  def status_pill(:paused),
    do: %{label: "Paused", icon: "hero-pause", class: "bg-warning/10 text-warning border border-warning/40"}

  def status_pill(:error),
    do: %{label: "Error", icon: "hero-exclamation-triangle", class: "bg-danger/10 text-danger border border-danger/40"}

  def status_pill(_active),
    do: %{label: "Active", icon: "hero-check-circle", class: "bg-success/10 text-success border border-success/40"}

  @doc """
  A compact, human-friendly label for a source's original URL. YouTube handle and
  channel URLs collapse to just the `@handle` (e.g.
  `https://www.youtube.com/@some-fake-channel` → `@some-fake-channel`) and playlist
  URLs to `#` plus the playlist ID (e.g.
  `https://www.youtube.com/playlist?list=PLxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` →
  `#PLxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`); anything else drops the scheme/`www.` and
  trailing slash. The value stays the link text — the `href` is still the full URL.
  """
  def source_url_label(url) when is_binary(url) do
    # The playlist ID is checked first: a playlist can live under a channel URL
    # (`/@someone/...?list=PL…`), where the list is what identifies the source.
    case {Regex.run(~r{[?&]list=([^&#]+)}, url), Regex.run(~r{/(@[^/?#]+)}, url)} do
      {[_, playlist_id], _} -> "##{playlist_id}"
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
    "Relative folder under the media root. Pinchflat applies this before the output template, so keep the template focused on filenames or subfolders inside this directory."
  end

  def download_subdirectory_examples do
    [
      "Kids/Bluey",
      "Podcasts/Tech",
      "TV/Documentaries"
    ]
  end

  defp compute_date_offset(days) do
    timezone = Application.get_env(:pinchflat, :timezone)

    timezone
    |> DateTime.now!()
    |> DateTime.add(-days, :day)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end
