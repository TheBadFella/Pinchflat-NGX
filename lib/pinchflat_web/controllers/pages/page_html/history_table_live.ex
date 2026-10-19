defmodule Pinchflat.Pages.HistoryTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery
  import Ecto.Query, warn: false
  import PinchflatWeb.Helpers.SortingHelpers
  import PinchflatWeb.CustomComponents.DatePicker, only: [date_picker: 1]

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Tasks
  alias Pinchflat.Tasks.Task
  alias PinchflatWeb.CustomComponents.TextComponents
  alias PinchflatWeb.Helpers.JobActionHelpers
  alias PinchflatWeb.Helpers.MediaCleanupHelpers

  @limit System.get_env("PAGINATION_HISTORY_LIMIT", System.get_env("PAGINATION_LIMIT", "10")) |> String.to_integer()
  @sort_fields %{
    "uploaded_at" => :uploaded_at,
    "inserted_at" => :inserted_at,
    "media_downloaded_at" => :media_downloaded_at
  }
  @error_type_filters %{"all" => nil, "transient" => :transient, "permanent" => :permanent}

  def render(%{records: []} = assigns) do
    ~H"""
    <.action_feedback feedback={@action_feedback} />
    <.latest_controls
      :if={@media_state == "latest"}
      grouping={@grouping}
      view_mode={@view_mode}
      sort_key={@sort_key}
      sort_direction={@sort_direction}
      time_range={@time_range}
    />
    <div class="mb-4 flex items-center">
      <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
      <p class="ml-2">{if @media_state == "latest", do: "No media indexed in this time frame.", else: "Nothing Here!"}</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <.action_feedback feedback={@action_feedback} />
      <.latest_controls
        :if={@media_state == "latest"}
        grouping={@grouping}
        view_mode={@view_mode}
        sort_key={@sort_key}
        sort_direction={@sort_direction}
        time_range={@time_range}
      />
      <span class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <span class="flex items-center">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
          <span class="ml-2">
            Showing <.localized_number number={length(@records)} /> of <.localized_number number={@total_record_count} />
          </span>
        </span>

        <.button
          :if={@media_state == "failed"}
          type="button"
          rounding="rounded-m3-sm"
          class="w-full text-sm sm:w-auto"
          phx-click="retry_all_failed"
          data-confirm="Retry all failed downloads? They go to the back of the queue."
        >
          <.icon name="hero-arrow-path" class="mr-1 h-4 w-4" /> Retry All Failed
        </.button>

        <form :if={@media_state == "failed"} id="history-error-type-filter" phx-change="filter_error_type">
          <label class="sr-only" for="history-error-type">Failure type</label>
          <select
            id="history-error-type"
            name="error_type"
            class="theme-input rounded-m3-sm text-sm"
          >
            <option value="all" selected={@error_type_filter == "all"}>All failures</option>

            <option value="transient" selected={@error_type_filter == "transient"}>Transient failures</option>

            <option value="permanent" selected={@error_type_filter == "permanent"}>Permanent failures</option>
          </select>
        </form>
      </span>

      <div class="space-y-6">
        <section :for={group <- record_groups(@records, @grouping)} data-source-id={group.source && group.source.id}>
          <h3 :if={group.source} class="mb-3 text-lg font-medium text-theme-on-surface">
            <.subtle_link href={~p"/sources/#{group.source.id}"}>{group.source.custom_name}</.subtle_link>
          </h3>

          <.history_records
            records={group.records}
            media_state={@media_state}
            view_mode={@view_mode}
            sort_key={@sort_key}
            sort_direction={@sort_direction}
            tasks_by_media_item_id={@tasks_by_media_item_id}
          />
        </section>
      </div>

      <section class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  attr :records, :list, required: true
  attr :media_state, :string, required: true
  attr :view_mode, :string, required: true
  attr :sort_key, :any, required: true
  attr :sort_direction, :atom, required: true
  attr :tasks_by_media_item_id, :map, required: true

  defp history_records(assigns) do
    ~H"""
    <div class={
      if @view_mode == "grid", do: "grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3", else: "space-y-4 md:hidden"
    }>
      <article :for={media_item <- @records} class="theme-surface-accent space-y-4 rounded-m3-lg p-4">
        <div class="flex flex-col gap-3">
          <div class="min-w-0 flex-1 space-y-2">
            <div class="flex flex-wrap items-start gap-2">
              <.icon
                :if={media_item.last_error}
                name="hero-exclamation-circle-solid"
                class="theme-status-error mt-0.5 shrink-0"
              /> <.failure_badge :if={@media_state == "failed"} error_type={media_item.error_type} />
              <div class="w-full min-w-0">
                <.subtle_link href={~p"/sources/#{media_item.source_id}/media/#{media_item.id}"}>
                  <span class="block whitespace-normal break-words font-medium text-theme-on-surface">
                    {media_item.title}
                  </span>
                </.subtle_link>
              </div>
            </div>

            <.subtle_link href={~p"/sources/#{media_item.source_id}"}>
              <span class="text-sm text-theme-on-surface-muted">{media_item.source.custom_name}</span>
            </.subtle_link>

            <.media_status
              :if={@media_state == "latest"}
              media_item={media_item}
              task={Map.get(@tasks_by_media_item_id, media_item.id)}
            />
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <.icon_button
              :if={is_nil(media_item.media_downloaded_at) and @media_state != "failed"}
              icon_name="hero-arrow-down-tray"
              class="h-10 w-10"
              phx-click="force_download"
              phx-value-media-id={media_item.id}
              data-confirm={MediaCleanupHelpers.download_confirmation(media_item, media_item.source)}
              tooltip="Force Download"
              tooltip_position="bottom-left"
            />
            <.icon_button
              :if={@media_state == "failed" and media_item.error_type != :permanent}
              icon_name="hero-arrow-path"
              class="h-10 w-10"
              phx-click="retry_download"
              phx-value-media-id={media_item.id}
              data-confirm={
                MediaCleanupHelpers.download_confirmation(media_item, media_item.source, "Retry this download now?")
              }
              tooltip="Retry Now"
              tooltip_position="bottom-left"
            />
            <.icon_button
              :if={@media_state == "failed" and media_item.error_type == :permanent}
              icon_name="hero-arrow-path"
              class="h-10 w-10"
              phx-click="force_download"
              phx-value-media-id={media_item.id}
              data-confirm={
                MediaCleanupHelpers.download_confirmation(
                  media_item,
                  media_item.source,
                  "Force a retry of this permanent failure?"
                )
              }
              tooltip="Force Retry"
              tooltip_position="bottom-left"
            />
            <.icon_button
              :if={Map.has_key?(@tasks_by_media_item_id, media_item.id)}
              icon_name="hero-stop-solid"
              variant="danger"
              class="h-10 w-10"
              phx-click="stop_download"
              phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
              data-confirm="Are you sure you want to stop this download?"
              tooltip="Stop Download"
              tooltip_position="bottom-left"
            />
          </div>
        </div>

        <.download_failure
          :if={media_item.last_error}
          media_item={media_item}
          task={Map.get(@tasks_by_media_item_id, media_item.id)}
        />
        <dl class="grid grid-cols-1 gap-3 text-sm">
          <div class="flex items-start justify-between gap-3">
            <dt class="text-theme-on-surface-muted">Upload Date</dt>

            <dd class="min-w-0 break-words text-right text-theme-on-surface">{DateTime.to_date(media_item.uploaded_at)}</dd>
          </div>

          <div class="flex items-start justify-between gap-3">
            <dt class="text-theme-on-surface-muted">Size / Progress</dt>

            <dd class="min-w-0 max-w-[65%] break-words text-right text-theme-on-surface">
              <.progress_details media_item={media_item} task={Map.get(@tasks_by_media_item_id, media_item.id)} />
            </dd>
          </div>

          <div class="flex items-start justify-between gap-3">
            <dt class="text-theme-on-surface-muted">Indexed At</dt>

            <dd class="min-w-0 break-words text-right text-theme-on-surface">{format_datetime(media_item.inserted_at)}</dd>
          </div>

          <div class="flex items-start justify-between gap-3">
            <dt class="text-theme-on-surface-muted">Downloaded At</dt>

            <dd class="min-w-0 break-words text-right text-theme-on-surface">
              {format_datetime(media_item.media_downloaded_at)}
            </dd>
          </div>
        </dl>
      </article>
    </div>

    <div :if={@view_mode == "list"} class="hidden md:block">
      <div class="max-w-full overflow-visible">
        <div class="overflow-x-auto overflow-y-hidden">
          <.table rows={@records} sort_key={@sort_key} sort_direction={@sort_direction}>
            <:col :let={media_item} label="Title" class="max-w-sm">
              <section class="space-y-2">
                <div class="flex items-start space-x-1 gap-2">
                  <.icon
                    :if={media_item.last_error}
                    name="hero-exclamation-circle-solid"
                    class="theme-status-error shrink-0"
                  /> <.failure_badge :if={@media_state == "failed"} error_type={media_item.error_type} />
                  <.icon_button
                    :if={is_nil(media_item.media_downloaded_at) and @media_state != "failed"}
                    icon_name="hero-arrow-down-tray"
                    class="h-10 w-10"
                    phx-click="force_download"
                    phx-value-media-id={media_item.id}
                    data-confirm={MediaCleanupHelpers.download_confirmation(media_item, media_item.source)}
                    tooltip="Force Download"
                    tooltip_position="bottom-left"
                  />
                  <.icon_button
                    :if={@media_state == "failed" and media_item.error_type != :permanent}
                    icon_name="hero-arrow-path"
                    class="h-10 w-10"
                    phx-click="retry_download"
                    phx-value-media-id={media_item.id}
                    data-confirm={
                      MediaCleanupHelpers.download_confirmation(media_item, media_item.source, "Retry this download now?")
                    }
                    tooltip="Retry Now"
                    tooltip_position="bottom-left"
                  />
                  <.icon_button
                    :if={@media_state == "failed" and media_item.error_type == :permanent}
                    icon_name="hero-arrow-path"
                    class="h-10 w-10"
                    phx-click="force_download"
                    phx-value-media-id={media_item.id}
                    data-confirm={
                      MediaCleanupHelpers.download_confirmation(
                        media_item,
                        media_item.source,
                        "Force a retry of this permanent failure?"
                      )
                    }
                    tooltip="Force Retry"
                    tooltip_position="bottom-left"
                  />
                  <.subtle_link href={~p"/sources/#{media_item.source_id}/media/#{media_item.id}"}>
                    <span class="block whitespace-normal break-words">{media_item.title}</span>
                  </.subtle_link>
                </div>

                <.download_failure
                  :if={media_item.last_error}
                  media_item={media_item}
                  task={Map.get(@tasks_by_media_item_id, media_item.id)}
                />
              </section>
            </:col>

            <:col :let={media_item} :if={@media_state == "latest"} label="Status">
              <.media_status media_item={media_item} task={Map.get(@tasks_by_media_item_id, media_item.id)} />
            </:col>

            <:col :let={media_item} label="Upload Date" sort_key="uploaded_at">
              {DateTime.to_date(media_item.uploaded_at)}
            </:col>

            <:col :let={media_item} label="Size / Progress">
              <.progress_details media_item={media_item} task={Map.get(@tasks_by_media_item_id, media_item.id)} />
            </:col>

            <:col :let={media_item} label="Indexed At" sort_key="inserted_at">
              {format_datetime(media_item.inserted_at)}
            </:col>

            <:col :let={media_item} label="Downloaded At" sort_key="media_downloaded_at">
              {format_datetime(media_item.media_downloaded_at)}
            </:col>

            <:col :let={media_item} label="Source" class="max-w-sm">
              <.subtle_link href={~p"/sources/#{media_item.source_id}"}>
                <span class="block whitespace-normal break-words">{media_item.source.custom_name}</span>
              </.subtle_link>
            </:col>

            <:col :let={media_item} label="Action">
              <.icon_button
                :if={Map.has_key?(@tasks_by_media_item_id, media_item.id)}
                icon_name="hero-stop-solid"
                variant="danger"
                class="h-10 w-10"
                phx-click="stop_download"
                phx-value-task-id={Map.fetch!(@tasks_by_media_item_id, media_item.id).id}
                data-confirm="Are you sure you want to stop this download?"
                tooltip="Stop Download"
                tooltip_position="bottom-left"
              />
              <span :if={!Map.has_key?(@tasks_by_media_item_id, media_item.id)} class="text-theme-on-surface-muted">
                -
              </span>
            </:col>
          </.table>
        </div>
      </div>
    </div>
    """
  end

  attr :grouping, :string, required: true
  attr :time_range, :map, required: true
  attr :view_mode, :string, required: true
  attr :sort_key, :atom, required: true
  attr :sort_direction, :atom, required: true

  defp latest_controls(assigns) do
    ~H"""
    <div id="latest-toolbar">
      <div
        id="latest-mobile-controls"
        class="theme-surface-accent mb-4 space-y-3 rounded-m3-lg border border-theme-outline p-3 sm:hidden"
      >
        <form action={~p"/"} method="get">
          <input type="hidden" name="tab" value="latest" />
          <input type="hidden" name="from" value={@time_range.from} /><input type="hidden" name="to" value={@time_range.to} />
          <div class="flex gap-1 rounded-m3-sm border border-theme-outline p-1" role="group" aria-label="Indexed time frame">
            <button
              :for={{value, label} <- [{"day", "1 day"}, {"week", "7 days"}]}
              type="submit"
              name="range"
              value={value}
              aria-pressed={to_string(@time_range.range == value)}
              class={[
                "theme-filter-button min-w-0 flex-1 justify-center whitespace-nowrap rounded-m3-xs px-1!",
                if(@time_range.range == value,
                  do: "bg-theme-primary text-theme-on-primary",
                  else: "text-theme-on-surface-muted"
                )
              ]}
            >{label}</button>
            <button
              type="button"
              class={[
                "theme-filter-button min-w-0 flex-1 justify-center whitespace-nowrap rounded-m3-xs px-1!",
                if(@time_range.range == "custom",
                  do: "bg-theme-primary text-theme-on-primary",
                  else: "text-theme-on-surface-muted"
                )
              ]}
              aria-pressed={to_string(@time_range.range == "custom")}
              aria-haspopup="dialog"
              aria-controls="latest-filter-sheet"
              phx-click={JS.dispatch("open-dialog", to: "#latest-filter-sheet", detail: %{custom: true})}
            >Custom</button>
          </div>
        </form>

        <div class="flex items-center justify-between gap-2">
          <.button
            type="button"
            variant="outline"
            aria-haspopup="dialog"
            aria-controls="latest-filter-sheet"
            phx-click={JS.dispatch("open-dialog", to: "#latest-filter-sheet")}
          >
            <.icon name="hero-adjustments-horizontal" class="mr-2 h-4 w-4" /> Filters
          </.button>

          <.view_choices
            label="Latest layout"
            event="view_change"
            value_name="view"
            selected={@view_mode}
            choices={[{"list", "List", "hero-list-bullet"}, {"grid", "Grid", "hero-squares-2x2"}]}
            icons_only
          />
        </div>

        <p id="latest-mobile-summary" class="text-xs text-theme-on-surface-muted" aria-live="polite">
          {if @grouping == "source", do: "By source", else: "Latest first"} · {Map.fetch!(
            %{inserted_at: "Indexed at", uploaded_at: "Upload date", media_downloaded_at: "Downloaded at"},
            @sort_key
          )} · {if @sort_direction == :desc, do: "Newest first", else: "Oldest first"}
        </p>

        <p :if={@time_range.range == "custom"} class="text-xs text-theme-on-surface-muted">
          {@time_range.from} – {@time_range.to}
        </p>

        <p :if={@time_range.error} role="alert" class="theme-status-error text-sm">{@time_range.error}</p>
      </div>

      <div id="latest-desktop-controls" class="hidden sm:block mb-4 space-y-3 border-b border-theme-outline/70 pb-4">
        <div class="flex flex-wrap items-end gap-3">
          <div class="flex flex-wrap items-center gap-2">
            <.view_choices
              label="Latest grouping"
              event="grouping_change"
              value_name="grouping"
              selected={@grouping}
              choices={[{"latest", "Latest", "hero-clock"}, {"source", "By source", "hero-rectangle-stack"}]}
            />
            <.view_choices
              label="Latest layout"
              event="view_change"
              value_name="view"
              selected={@view_mode}
              choices={[{"list", "List", "hero-list-bullet"}, {"grid", "Grid", "hero-squares-2x2"}]}
            />
          </div>

          <form action={~p"/"} method="get" class="shrink-0">
            <input type="hidden" name="tab" value="latest" /> <input type="hidden" name="from" value={@time_range.from} />
            <input type="hidden" name="to" value={@time_range.to} />
            <div
              class="inline-flex items-center gap-1 rounded-m3-sm border border-theme-outline bg-theme-surface p-1"
              role="group"
              aria-label="Indexed time frame"
            >
              <button
                :for={{value, label} <- [{"day", "1 day"}, {"week", "7 days"}, {"custom", "Custom"}]}
                type="submit"
                name="range"
                value={value}
                aria-pressed={to_string(@time_range.range == value)}
                class={[
                  "inline-flex min-h-11 items-center rounded-m3-xs px-3 py-2 text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70 lg:px-2 2xl:px-3",
                  if(@time_range.range == value,
                    do: "bg-theme-primary text-theme-on-primary",
                    else: "text-theme-on-surface-muted hover:bg-theme-surface-2 hover:text-theme-on-surface"
                  )
                ]}
              >{label}</button>
            </div>
          </form>

          <form
            :if={@time_range.range == "custom"}
            id="latest-custom-range"
            action={~p"/"}
            method="get"
            class="grid w-full grid-cols-2 items-end gap-3 sm:w-auto sm:flex"
          >
            <input type="hidden" name="tab" value="latest" /> <input type="hidden" name="range" value="custom" />
            <div class="min-w-0 sm:w-36">
              <.date_picker
                id="latest-from"
                name="from"
                label="From"
                value={@time_range.from}
                timezone={@time_range.timezone}
              />
            </div>

            <div class="min-w-0 sm:w-36">
              <.date_picker id="latest-to" name="to" label="To" value={@time_range.to} timezone={@time_range.timezone} />
            </div>
            <.button type="submit" variant="primary">Apply</.button>
            <p :if={@time_range.error} role="alert" class="theme-status-error col-span-2 w-full text-sm">
              {@time_range.error}
            </p>
          </form>

          <form
            id="latest-sort"
            phx-change="latest_sort"
            class="grid w-full grid-cols-2 items-end gap-3 sm:ml-auto sm:w-auto lg:w-72 2xl:w-auto"
          >
            <.input
              type="select"
              id="latest-sort-key"
              name="sort_key"
              label="Sort by"
              value={@sort_key}
              options={[
                {"Indexed At", :inserted_at},
                {"Upload Date", :uploaded_at},
                {"Downloaded At", :media_downloaded_at}
              ]}
              inputclass="min-h-11 gap-2! px-3! py-2 text-sm"
            />
            <.input
              type="select"
              id="latest-sort-direction"
              name="sort_direction"
              label="Order"
              value={@sort_direction}
              options={[{"Newest first", :desc}, {"Oldest first", :asc}]}
              inputclass="min-h-11 gap-2! px-3! py-2 text-sm"
            />
          </form>
        </div>

        <div class="flex flex-wrap gap-x-3 gap-y-1">
          <p :if={@time_range.range != "custom"} class="text-xs text-theme-on-surface-muted">
            {if @time_range.range == "day", do: "Indexed in the past 24 hours.", else: "Indexed in the past 7 days."}
          </p>

          <p :if={@grouping == "source"} class="w-full text-xs text-theme-on-surface-muted">
            Sources are ordered by their latest indexed item. The date sort applies within each source.
          </p>
        </div>
      </div>

      <dialog
        id="latest-filter-sheet"
        phx-hook="ResponsiveDialog"
        class="theme-bottom-sheet"
        aria-labelledby="latest-filter-title"
      >
        <div class="flex items-center justify-between gap-3">
          <h2 id="latest-filter-title" class="text-lg font-semibold">Filter &amp; sort</h2>

          <.button
            type="button"
            variant="outline"
            phx-click={JS.dispatch("close-dialog", to: "#latest-filter-sheet")}
            aria-label="Close filters"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </.button>
        </div>

        <div class="mt-4 space-y-4">
          <div>
            <p class="mb-1 text-sm font-medium text-theme-on-surface-muted">Group media</p>

            <.view_choices
              label="Latest grouping"
              event="grouping_change"
              value_name="grouping"
              selected={@grouping}
              choices={[{"latest", "Latest", "hero-clock"}, {"source", "By source", "hero-rectangle-stack"}]}
            />
            <p :if={@grouping == "source"} class="mt-2 text-xs text-theme-on-surface-muted">
              Sources are ordered by their latest indexed item. Sorting applies within each source.
            </p>
          </div>

          <form
            id="latest-mobile-sort"
            phx-change="latest_sort"
            class="grid w-full grid-cols-1 items-end gap-3"
          >
            <.input
              type="select"
              id="latest-mobile-sort-key"
              name="sort_key"
              label="Sort by"
              value={@sort_key}
              options={[
                {"Indexed At", :inserted_at},
                {"Upload Date", :uploaded_at},
                {"Downloaded At", :media_downloaded_at}
              ]}
              inputclass="min-h-11 gap-2! px-3! py-2 text-sm"
            />
            <.input
              type="select"
              id="latest-mobile-sort-direction"
              name="sort_direction"
              label="Order"
              value={@sort_direction}
              options={[{"Newest first", :desc}, {"Oldest first", :asc}]}
              inputclass="min-h-11 gap-2! px-3! py-2 text-sm"
            />
          </form>

          <details id="latest-mobile-dates" open={@time_range.range == "custom"}>
            <summary class="theme-filter-button cursor-pointer rounded-m3-sm">Custom date range</summary>

            <form
              id="latest-mobile-custom-range"
              action={~p"/"}
              method="get"
              class="grid w-full grid-cols-1 items-end gap-3"
            >
              <input type="hidden" name="tab" value="latest" /> <input type="hidden" name="range" value="custom" />
              <div class="min-w-0">
                <.date_picker
                  id="latest-mobile-from"
                  name="from"
                  label="From"
                  value={@time_range.from}
                  timezone={@time_range.timezone}
                />
              </div>

              <div class="min-w-0">
                <.date_picker
                  id="latest-mobile-to"
                  name="to"
                  label="To"
                  value={@time_range.to}
                  timezone={@time_range.timezone}
                />
              </div>
              <.button type="submit" variant="primary" class="w-full">Apply date range</.button>
              <p :if={@time_range.error} role="alert" class="theme-status-error w-full text-sm">
                {@time_range.error}
              </p>
            </form>

            <p class="mt-2 text-xs text-theme-on-surface-muted">
              Dates use {@time_range.timezone}. Both dates are included.
            </p>
          </details>

          <.button
            type="button"
            variant="primary"
            class="w-full"
            phx-click={JS.dispatch("close-dialog", to: "#latest-filter-sheet")}
          >Done</.button>
        </div>
      </dialog>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :value_name, :string, required: true
  attr :selected, :string, required: true
  attr :choices, :list, required: true

  attr :icons_only, :boolean, default: false

  defp view_choices(assigns) do
    ~H"""
    <div
      class="inline-flex items-center gap-1 rounded-m3-sm border border-theme-outline bg-theme-surface p-1"
      role="group"
      aria-label={@label}
    >
      <button
        :for={{value, label, icon} <- @choices}
        type="button"
        class={[
          "inline-flex min-h-11 min-w-11 items-center justify-center gap-2 rounded-m3-xs px-3 py-2 text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70 lg:px-2 2xl:px-3",
          if(value == @selected,
            do: "bg-theme-primary text-theme-on-primary",
            else: "text-theme-on-surface-muted hover:bg-theme-surface-2 hover:text-theme-on-surface"
          )
        ]}
        phx-click={@event}
        {[{"phx-value-#{@value_name}", value}]}
        aria-pressed={to_string(value == @selected)}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="h-4 w-4" aria-hidden="true" />
        <span class={if @icons_only, do: "sr-only", else: "lg:hidden 2xl:inline"}>{label}</span>
      </button>
    </div>
    """
  end

  defp record_groups(records, "source") do
    records
    |> Enum.chunk_by(& &1.source_id)
    |> Enum.map(fn items -> %{source: hd(items).source, records: items} end)
  end

  defp record_groups(records, _grouping), do: [%{source: nil, records: records}]

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("job:progress")

    page = 1
    media_state = session["media_state"]
    error_type_filter = "all"
    sort_key = if media_state == "latest", do: :inserted_at
    sort_direction = :desc
    base_query = generate_base_query(media_state, error_type_filter)
    time_range = normalize_time_range(session["latest_range"] || %{})
    base_query = if media_state == "latest", do: latest_query(time_range, "latest"), else: base_query
    pagination_attrs = fetch_pagination_attributes(base_query, page, media_state, sort_key, sort_direction)

    {:ok,
     assign(
       socket,
       Map.merge(pagination_attrs, %{
         base_query: base_query,
         action_feedback: nil,
         media_state: media_state,
         grouping: "latest",
         view_mode: "list",
         time_range: time_range,
         error_type_filter: error_type_filter,
         sort_key: sort_key,
         sort_direction: sort_direction
       })
     )}
  end

  def handle_event("view_change", %{"view" => view}, socket) when view in ~w(list grid) do
    {:noreply, assign(socket, :view_mode, view)}
  end

  def handle_event("view_change", _params, socket), do: {:noreply, socket}

  def handle_event(
        "grouping_change",
        %{"grouping" => grouping},
        %{assigns: %{media_state: "latest"} = assigns} = socket
      )
      when grouping in ~w(latest source) do
    base_query = latest_query(assigns.time_range, grouping)
    pagination = fetch_pagination_attributes(base_query, 1, "latest", assigns.sort_key, assigns.sort_direction)
    {:noreply, assign(socket, Map.merge(pagination, %{base_query: base_query, grouping: grouping}))}
  end

  def handle_event("grouping_change", _params, socket), do: {:noreply, socket}

  def handle_event("latest_sort", %{"sort_key" => key, "sort_direction" => direction}, %{assigns: assigns} = socket)
      when direction in ~w(asc desc) do
    case Map.fetch(@sort_fields, key) do
      {:ok, sort_key} ->
        sort_direction = if direction == "asc", do: :asc, else: :desc
        pagination = fetch_pagination_attributes(assigns.base_query, 1, assigns.media_state, sort_key, sort_direction)
        {:noreply, assign(socket, Map.merge(pagination, %{sort_key: sort_key, sort_direction: sort_direction}))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("latest_sort", _params, socket), do: {:noreply, socket}

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    direction = if direction == "inc", do: 1, else: -1
    new_page = assigns.page + direction

    new_assigns =
      fetch_pagination_attributes(
        assigns.base_query,
        new_page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("sort_update", %{"sort_key" => sort_key}, %{assigns: assigns} = socket) do
    case Map.fetch(@sort_fields, sort_key) do
      {:ok, new_sort_key} ->
        new_sort_direction = get_sort_direction(assigns.sort_key, new_sort_key, assigns.sort_direction)

        new_assigns =
          fetch_pagination_attributes(
            assigns.base_query,
            1,
            assigns.media_state,
            new_sort_key,
            new_sort_direction
          )

        {:noreply,
         assign(socket, Map.merge(new_assigns, %{sort_key: new_sort_key, sort_direction: new_sort_direction}))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("filter_error_type", %{"error_type" => error_type}, %{assigns: assigns} = socket) do
    error_type_filter = if Map.has_key?(@error_type_filters, error_type), do: error_type, else: "all"
    base_query = generate_base_query(assigns.media_state, error_type_filter)

    pagination_attrs =
      fetch_pagination_attributes(
        base_query,
        1,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply,
     assign(socket, Map.merge(pagination_attrs, %{base_query: base_query, error_type_filter: error_type_filter}))}
  end

  def handle_event("reload_page", _params, %{assigns: assigns} = socket) do
    base_query =
      if assigns.media_state == "latest",
        do: latest_query(assigns.time_range, assigns.grouping),
        else: assigns.base_query

    new_assigns =
      fetch_pagination_attributes(
        base_query,
        assigns.page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, Map.put(new_assigns, :base_query, base_query))}
  end

  def handle_event("force_download", %{"media-id" => media_id}, %{assigns: assigns} = socket) do
    media_item = Media.get_media_item!(media_id)
    result = MediaDownloadWorker.kickoff_with_task(media_item, %{force: true, reset_last_error: true})
    socket = assign(socket, :action_feedback, JobActionHelpers.feedback(result))

    new_assigns =
      fetch_pagination_attributes(
        assigns.base_query,
        assigns.page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("retry_download", %{"media-id" => media_id}, %{assigns: assigns} = socket) do
    media_item = Media.get_media_item!(media_id)
    result = MediaDownloadWorker.kickoff_with_task(media_item, %{reset_last_error: true})
    socket = assign(socket, :action_feedback, JobActionHelpers.feedback(result))

    new_assigns =
      fetch_pagination_attributes(
        assigns.base_query,
        assigns.page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("retry_all_failed", _params, %{assigns: assigns} = socket) do
    results = DownloadingHelpers.retry_failed_download_tasks()
    socket = assign(socket, :action_feedback, JobActionHelpers.feedback(results))

    new_assigns =
      fetch_pagination_attributes(
        assigns.base_query,
        assigns.page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("stop_download", %{"task-id" => task_id}, %{assigns: assigns} = socket) do
    task = Repo.get(Task, task_id)

    if task do
      {:ok, _task} = Tasks.delete_task(task)
    end

    new_assigns =
      fetch_pagination_attributes(
        assigns.base_query,
        assigns.page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_info(%{topic: "job:state", event: "change", payload: payload}, %{assigns: assigns} = socket)
      when is_map(payload) do
    if refresh_required?(payload) do
      new_assigns =
        fetch_pagination_attributes(
          assigns.base_query,
          assigns.page,
          assigns.media_state,
          assigns.sort_key,
          assigns.sort_direction
        )

      {:noreply, assign(socket, new_assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: assigns} = socket) do
    new_assigns =
      fetch_pagination_attributes(
        assigns.base_query,
        assigns.page,
        assigns.media_state,
        assigns.sort_key,
        assigns.sort_direction
      )

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_info(%{topic: "job:progress", event: "update", payload: payload}, socket) when is_map(payload) do
    updated_tasks =
      update_task_progress(socket.assigns.tasks_by_media_item_id, socket.assigns.records, payload)

    {:noreply, assign(socket, :tasks_by_media_item_id, updated_tasks)}
  end

  def handle_info(%{topic: "job:progress", event: "update"}, socket) do
    {:noreply, socket}
  end

  defp fetch_pagination_attributes(base_query, page, media_state, sort_key, sort_direction) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)
    sorted_query = order_records(base_query, media_state, sort_key, sort_direction)

    if media_state == "pending" do
      records = fetch_records(sorted_query, page)

      tasks_by_media_item_id = fetch_download_tasks(records)

      %{
        page: page,
        total_pages: total_pages,
        records: records,
        total_record_count: total_record_count,
        tasks_by_media_item_id: tasks_by_media_item_id
      }
    else
      records = fetch_records(sorted_query, page)

      %{
        page: page,
        total_pages: total_pages,
        records: records,
        total_record_count: total_record_count,
        tasks_by_media_item_id: fetch_download_tasks(records)
      }
    end
  end

  defp fetch_records(base_query, page) do
    offset = (page - 1) * @limit

    base_query
    |> limit(^@limit)
    |> offset(^offset)
    |> Repo.all()
    |> Repo.preload(:source)
  end

  defp generate_base_query(media_state, error_type_filter) do
    query = generate_base_query_for_state(media_state)

    if media_state == "failed" do
      where(query, ^error_type_condition(error_type_filter))
    else
      query
    end
  end

  defp generate_base_query_for_state("latest"), do: MediaQuery.new()

  defp generate_base_query_for_state("pending") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.pending()))
    |> select(
      [m],
      struct(m, [
        :id,
        :title,
        :uploaded_at,
        :inserted_at,
        :media_downloaded_at,
        :source_id,
        :last_error,
        :prevent_download,
        :prevent_culling,
        :error_type,
        :download_prevented_reason,
        :media_size_bytes
      ])
    )
  end

  defp generate_base_query_for_state("failed") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.download_failed()))
    |> select(
      [m],
      struct(m, [
        :id,
        :title,
        :uploaded_at,
        :inserted_at,
        :media_downloaded_at,
        :source_id,
        :last_error,
        :prevent_download,
        :prevent_culling,
        :error_type,
        :download_prevented_reason,
        :media_size_bytes
      ])
    )
  end

  defp generate_base_query_for_state("downloaded") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.downloaded()))
    |> select(
      [m],
      struct(m, [
        :id,
        :title,
        :uploaded_at,
        :inserted_at,
        :media_downloaded_at,
        :source_id,
        :last_error,
        :prevent_download,
        :prevent_culling,
        :error_type,
        :download_prevented_reason,
        :media_size_bytes
      ])
    )
  end

  defp normalize_time_range(params) do
    range = if params["range"] in ~w(day week custom), do: params["range"], else: "day"
    timezone = Application.fetch_env!(:pinchflat, :timezone)
    today = timezone |> DateTime.now!() |> DateTime.to_date()
    from = date_param(params, "from", Date.add(today, -6))
    to = date_param(params, "to", today)

    error =
      if range == "custom" do
        with {:ok, first} <- Date.from_iso8601(from),
             {:ok, last} <- Date.from_iso8601(to),
             true <- Date.compare(first, last) != :gt do
          nil
        else
          _ -> "Enter valid dates with From on or before To."
        end
      end

    %{range: range, from: from, to: to, error: error, timezone: timezone}
  end

  defp date_param(params, key, default) do
    case params[key] do
      nil -> Date.to_iso8601(default)
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp latest_query(time_range, grouping) do
    query = filter_indexed_time(MediaQuery.new(), time_range)
    if grouping == "source", do: group_sources(query), else: query
  end

  defp filter_indexed_time(query, %{error: error}) when not is_nil(error), do: where(query, false)

  defp filter_indexed_time(query, %{range: "custom", from: first, to: last, timezone: timezone}) do
    first = start_of_date(Date.from_iso8601!(first), timezone)
    last = start_of_date(Date.add(Date.from_iso8601!(last), 1), timezone)
    where(query, [m], m.inserted_at >= ^first and m.inserted_at < ^last)
  end

  defp filter_indexed_time(query, %{range: range}) do
    days = if range == "week", do: 7, else: 1
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    where(query, [m], m.inserted_at >= ^cutoff)
  end

  defp start_of_date(date, timezone) do
    # Some zones change clocks at midnight; use the first instant of the local date.
    datetime =
      case DateTime.new(date, ~T[00:00:00], timezone) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _before, next} -> next
      end

    DateTime.shift_zone!(datetime, "Etc/UTC")
  end

  defp group_sources(query) do
    latest_by_source =
      from(m in query,
        group_by: m.source_id,
        select: %{source_id: m.source_id, indexed_at: max(m.inserted_at)}
      )

    from(m in query,
      join: source in subquery(latest_by_source),
      on: source.source_id == m.source_id,
      order_by: [desc: source.indexed_at, asc: m.source_id]
    )
  end

  defp error_type_condition(error_type_filter) do
    case Map.fetch!(@error_type_filters, error_type_filter) do
      nil -> dynamic([_media_item], true)
      error_type -> dynamic([media_item], media_item.error_type == ^error_type)
    end
  end

  defp order_records(base_query, "pending", nil, _sort_direction), do: order_pending_media(base_query)
  defp order_records(base_query, _media_state, nil, _sort_direction), do: order_by(base_query, desc: :id)

  defp order_records(base_query, _media_state, sort_key, sort_direction) do
    sort_field = Map.fetch!(@sort_fields, Atom.to_string(sort_key))

    sort_expression = dynamic([media_item], field(media_item, ^sort_field))

    nulls_last_expression =
      dynamic([media_item], fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", ^sort_expression))

    from(media_item in base_query,
      order_by: ^[{:asc, nulls_last_expression}, {sort_direction, sort_expression}, asc: :id]
    )
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end

  defp fetch_download_tasks(records) do
    media_item_ids = Enum.map(records, & &1.id)

    if media_item_ids == [] do
      %{}
    else
      from(t in Task,
        join: j in assoc(t, :job),
        where: t.media_item_id in ^media_item_ids,
        where: fragment("? LIKE ?", j.worker, ^"%.MediaDownloadWorker"),
        where: j.state in ^["available", "scheduled", "retryable", "executing"],
        preload: [job: j],
        order_by: [desc: t.inserted_at]
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn task, acc ->
        Map.put_new(acc, task.media_item_id, task)
      end)
    end
  end

  defp size_or_progress_label(media_item, nil) do
    case media_item.media_size_bytes do
      nil -> "Unknown"
      size -> readable_byte_size(size)
    end
  end

  defp size_or_progress_label(_media_item, task) do
    downloaded_bytes = task.progress_downloaded_bytes
    total_bytes = task.progress_total_bytes
    speed_bytes = task.progress_speed_bytes_per_second

    cond do
      total_bytes && downloaded_bytes ->
        remaining_bytes = max(total_bytes - downloaded_bytes, 0)

        "#{readable_byte_size(downloaded_bytes)} / #{readable_byte_size(total_bytes)} (#{readable_byte_size(remaining_bytes)} left)"
        |> maybe_append_speed(speed_bytes)

      total_bytes ->
        readable_byte_size(total_bytes)
        |> maybe_append_speed(speed_bytes)

      downloaded_bytes ->
        "#{readable_byte_size(downloaded_bytes)} downloaded"
        |> maybe_append_speed(speed_bytes)

      true ->
        (task.progress_status || "Queued")
        |> maybe_append_speed(speed_bytes)
    end
  end

  defp readable_byte_size(bytes) do
    {num, suffix} = NumberUtils.human_byte_size(bytes, precision: 1)
    "#{num} #{suffix}"
  end

  defp maybe_append_speed(text, nil), do: text
  defp maybe_append_speed(text, speed_bytes), do: "#{text} at #{readable_byte_size(speed_bytes)}/s"

  attr :media_item, :map, required: true
  attr :task, :any, default: nil

  defp progress_details(assigns) do
    ~H"""
    <div :if={is_nil(@task)} class="text-theme-on-surface">
      {size_or_progress_label(@media_item, nil)}
    </div>

    <div :if={!is_nil(@task)} class="w-40 max-w-full space-y-2 break-words">
      <div class="text-right text-theme-on-surface">{size_or_progress_label(@media_item, @task)}</div>

      <div class="h-2 overflow-hidden rounded-full bg-theme-surface-4">
        <div
          class="h-full rounded-full bg-theme-primary transition-all duration-300"
          style={"width: #{progress_percent(@task)}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp progress_percent(task) do
    task.progress_percent
    |> Kernel.||(0.0)
    |> max(0.0)
    |> min(100.0)
    |> trunc()
  end

  attr :error_type, :any, default: nil

  defp failure_badge(assigns) do
    {label, class} = failure_presentation(assigns.error_type)
    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["inline-flex whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-medium", @class]}>
      {@label}
    </span>
    """
  end

  defp failure_presentation(:transient), do: {"Transient failure", "theme-badge-warning"}
  defp failure_presentation(:permanent), do: {"Permanent failure", "theme-danger-panel"}
  defp failure_presentation(_unknown), do: {"Failure", "theme-danger-panel"}

  attr :media_item, :map, required: true
  attr :task, :any, default: nil

  defp media_status(assigns) do
    {label, class} = media_status_presentation(assigns.media_item, assigns.task)
    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span
      data-media-status={@media_item.id}
      class={["inline-flex whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-medium", @class]}
    >
      {@label}
    </span>
    """
  end

  defp media_status_presentation(_item, %{job: %{state: "executing"}}),
    do: {"Downloading", "bg-theme-primary-container text-theme-on-primary-container"}

  defp media_status_presentation(_item, %{job: %{state: state}}) when state in ~w(available scheduled retryable),
    do:
      {if(state == "retryable", do: "Retrying", else: "Queued"),
       "bg-theme-primary-container text-theme-on-primary-container"}

  defp media_status_presentation(item, _task) do
    cond do
      item.media_filepath != nil -> {"Downloaded", "theme-badge-success"}
      item.prevent_download and item.download_prevented_reason != :error -> {"Prevented", "theme-badge-warning"}
      item.last_error != nil -> failure_presentation(item.error_type)
      true -> {"Pending", "bg-theme-surface-4 text-theme-on-surface-muted"}
    end
  end

  defp update_task_progress(tasks_by_media_item_id, records, %{media_item_id: media_item_id} = payload)
       when is_integer(media_item_id) do
    if Enum.any?(records, &(&1.id == media_item_id)) do
      task = Map.get(tasks_by_media_item_id, media_item_id, %Task{id: payload[:task_id], job_id: payload.job_id})
      Map.put(tasks_by_media_item_id, media_item_id, struct(task, Map.take(payload, progress_fields())))
    else
      tasks_by_media_item_id
    end
  end

  defp update_task_progress(tasks_by_media_item_id, _records, _payload), do: tasks_by_media_item_id

  defp order_pending_media(base_query) do
    latest_task_ids = latest_active_download_task_ids_query()

    from(media_item in exclude(base_query, :order_by),
      left_join: latest_task in subquery(latest_task_ids),
      on: latest_task.media_item_id == media_item.id,
      left_join: task in Task,
      on: task.id == latest_task.task_id,
      left_join: job in Oban.Job,
      on: job.id == task.job_id,
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? = 'executing' THEN 0 WHEN ? IS NOT NULL THEN 1 ELSE 2 END",
            job.state,
            task.id
          ),
        asc: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", task.inserted_at),
        asc: task.inserted_at,
        desc: media_item.uploaded_at,
        desc: media_item.id
      ]
    )
  end

  defp latest_active_download_task_ids_query do
    from(task in Task,
      join: job in assoc(task, :job),
      where: fragment("? LIKE ?", job.worker, ^"%.MediaDownloadWorker"),
      where: job.state in ^["available", "scheduled", "retryable", "executing"],
      where: not is_nil(task.media_item_id),
      group_by: task.media_item_id,
      select: %{media_item_id: task.media_item_id, task_id: max(task.id)}
    )
  end

  defp refresh_required?(payload) do
    payload[:media_item_id] ||
      indexing_worker?(payload[:worker]) ||
      media_download_worker?(payload[:worker])
  end

  defp media_download_worker?(worker), do: is_binary(worker) and String.ends_with?(worker, "MediaDownloadWorker")

  defp indexing_worker?(worker),
    do: worker in ["Pinchflat.FastIndexing.FastIndexingWorker", "Pinchflat.SlowIndexing.MediaCollectionIndexingWorker"]

  defp progress_fields do
    [
      :id,
      :job_id,
      :media_item_id,
      :progress_percent,
      :progress_status,
      :progress_downloaded_bytes,
      :progress_total_bytes,
      :progress_eta_seconds,
      :progress_speed_bytes_per_second,
      :progress_updated_at
    ]
  end
end
