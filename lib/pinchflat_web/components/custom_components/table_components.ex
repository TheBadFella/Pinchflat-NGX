defmodule PinchflatWeb.CustomComponents.TableComponents do
  @moduledoc false
  use Phoenix.Component

  import PinchflatWeb.CoreComponents
  import PinchflatWeb.CustomComponents.TextComponents

  @doc """
  Renders a table component with the given rows and columns.

  ## Examples

      <.table rows={@users}>
        <:col :let={user} label="Name"><%= user.name %></:col>
      </.table>
  """
  attr :rows, :list, required: true
  attr :table_class, :string, default: ""
  attr :sort_key, :atom, default: nil
  attr :sort_direction, :atom, default: nil
  attr :compact, :boolean, default: false, doc: "tighter padding; wrapping columns shrink before it scrolls"
  attr :rounded, :boolean, default: true

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :label_icon, :string, doc: "an icon shown instead of the label, which stays the accessible name"
    attr :header, :any, doc: "rendered content for the header cell instead of the label, such as a select-all checkbox"
    attr :class, :string
    attr :sort_key, :string
  end

  def table(assigns) do
    ~H"""
    <div class={["overflow-hidden bg-theme-surface-1 shadow-m3-1", @rounded && "rounded-m3-lg"]}>
      <div class="overflow-x-auto overflow-y-hidden">
        <table class={[
          "min-w-full table-auto text-theme-on-surface",
          if(@compact, do: "w-full", else: "w-max"),
          @table_class
        ]}>
          <thead>
            <tr class="border-b border-theme-outline/70 bg-theme-surface-3 text-left">
              <th
                :for={col <- @col}
                class={[
                  "font-medium text-theme-on-surface",
                  if(@compact, do: "whitespace-nowrap px-2", else: "px-4"),
                  header_padding(@compact, col[:sort_key] && !col[:header]),
                  col[:sort_key] && !col[:header] && "relative",
                  col[:label_icon] && "text-center",
                  sorted_column?(@sort_key, col[:sort_key]) && "bg-theme-primary/10"
                ]}
                aria-sort={column_sort(@sort_key, @sort_direction, col[:sort_key])}
              >
                {col[:header]}
                <.tooltip :if={col[:label_icon] && !col[:header]} tooltip={col[:label]} position="bottom">
                  <.sort_button
                    :if={col[:sort_key]}
                    col={col}
                    sort_key={@sort_key}
                    sort_direction={@sort_direction}
                  />
                  <span :if={!col[:sort_key]} data-label={col[:label]}>
                    <.column_label label={col[:label]} icon={col[:label_icon]} />
                  </span>
                </.tooltip>
                <.sort_button
                  :if={col[:sort_key] && !col[:header] && !col[:label_icon]}
                  col={col}
                  sort_key={@sort_key}
                  sort_direction={@sort_direction}
                />
                <span :if={!col[:sort_key] && !col[:header] && !col[:label_icon]}>
                  <.column_label label={col[:label]} icon={col[:label_icon]} />
                </span>
              </th>
            </tr>
          </thead>

          <tbody class="divide-y divide-theme-outline/60">
            <tr :for={row <- @rows} class="transition hover:bg-theme-surface-2">
              <td
                :for={col <- @col}
                class={[
                  "text-theme-on-surface-muted",
                  if(@compact, do: "px-2 py-2.5", else: "px-4 py-5"),
                  col[:class]
                ]}
              >
                {render_slot(col, @row_item.(row))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :col, :map, required: true
  attr :sort_key, :atom, default: nil
  attr :sort_direction, :atom, default: nil

  defp sort_button(assigns) do
    assigns = assign(assigns, :sorted, sorted_column?(assigns.sort_key, assigns.col[:sort_key]))

    ~H"""
    <button
      type="button"
      class={[
        "theme-filter-button -mx-3 -my-1 flex-col gap-0 rounded-m3-xs py-0.5 align-middle",
        "after:absolute after:inset-0",
        if(@sorted, do: "text-theme-primary", else: "hover:text-theme-primary")
      ]}
      phx-click="sort_update"
      phx-value-sort_key={@col[:sort_key]}
      aria-label={sort_button_label(@col[:label], @sort_key, @sort_direction, @col[:sort_key])}
      data-label={@col[:label]}
      data-sorted={@sorted && to_string(@sort_direction)}
    >
      <%!-- The arrow sits above the label when ascending and below it when descending, so it adds no width. --%>
      <.sort_arrow visible={@sorted and @sort_direction == :asc} direction="up" />
      <.column_label label={@col[:label]} icon={@col[:label_icon]} />
      <.sort_arrow visible={@sorted and @sort_direction != :asc} direction="down" />
    </button>
    """
  end

  attr :visible, :boolean, required: true
  attr :direction, :string, required: true, values: ["up", "down"]

  defp sort_arrow(assigns) do
    ~H"""
    <span
      class={["flex h-2.5 justify-center", if(@direction == "up", do: "items-start", else: "items-end")]}
      aria-hidden="true"
      data-sort-arrow={@visible && @direction}
    >
      <svg :if={@visible} viewBox="0 0 10 6" class="h-1.5 w-2.5" fill="currentColor">
        <path d={if @direction == "up", do: "M5 0 10 6H0z", else: "M5 6 10 0H0z"} />
      </svg>
    </span>
    """
  end

  attr :label, :string, default: nil
  attr :icon, :string, default: nil

  defp column_label(%{icon: nil} = assigns), do: ~H"{@label}"

  defp column_label(assigns) do
    ~H"""
    <.icon name={@icon} class="h-5 w-5" aria-hidden="true" /><span class="sr-only">{@label}</span>
    """
  end

  # Sort buttons are taller than plain labels, so their cells take less padding to keep one row height.
  defp header_padding(true, sortable), do: if(sortable, do: "py-1", else: "py-2")
  defp header_padding(false, sortable), do: if(sortable, do: "py-3", else: "py-4")

  defp sorted_column?(_sort_key, nil), do: false
  defp sorted_column?(sort_key, column_key), do: to_string(sort_key) == column_key

  defp column_sort(sort_key, sort_direction, column_key) do
    if to_string(sort_key) == column_key do
      if sort_direction == :asc, do: "ascending", else: "descending"
    else
      "none"
    end
  end

  defp sort_button_label(label, sort_key, sort_direction, column_key) do
    if to_string(sort_key) == column_key do
      direction = if sort_direction == :asc, do: "ascending", else: "descending"
      next_direction = if sort_direction == :asc, do: "descending", else: "ascending"
      "Sort by #{label}, currently #{direction}. Activate to sort #{next_direction}."
    else
      "Sort by #{label}"
    end
  end

  @doc """
  Renders simple pagination controls for a table in a liveview.

  ## Examples

      <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
  """
  attr :page_number, :integer, default: 1
  attr :total_pages, :integer, default: 1

  def live_pagination_controls(assigns) do
    ~H"""
    <nav aria-label="Pagination">
      <ul class="flex flex-wrap items-center">
        <li>
          <button
            type="button"
            disabled={@page_number <= 1}
            aria-label="Previous page"
            aria-disabled={to_string(@page_number <= 1)}
            class={[
              "pagination-prev theme-touch-target inline-flex h-9 w-9 min-h-9 min-w-9 items-center justify-center rounded-m3-xs transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70 focus-visible:ring-offset-2 focus-visible:ring-offset-theme-bg max-sm:h-11 max-sm:w-11 max-sm:min-h-11 max-sm:min-w-11",
              @page_number > 1 &&
                "cursor-pointer bg-theme-surface text-theme-on-surface hover:bg-theme-primary hover:text-theme-on-primary",
              @page_number <= 1 && "cursor-not-allowed opacity-50 bg-theme-surface text-theme-on-surface-muted"
            ]}
            phx-click={@page_number > 1 && "page_change"}
            phx-value-direction="dec"
          >
            <.icon name="hero-chevron-left" class="h-4 w-4" />
          </button>
        </li>

        <li>
          <span class="mx-2 text-sm font-medium">
            Page <.localized_number number={@page_number} /> of <.localized_number number={@total_pages} />
          </span>
        </li>

        <li>
          <button
            type="button"
            disabled={@page_number >= @total_pages}
            aria-label="Next page"
            aria-disabled={to_string(@page_number >= @total_pages)}
            class={[
              "pagination-next theme-touch-target inline-flex h-9 w-9 min-h-9 min-w-9 items-center justify-center rounded-m3-xs transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70 focus-visible:ring-offset-2 focus-visible:ring-offset-theme-bg max-sm:h-11 max-sm:w-11 max-sm:min-h-11 max-sm:min-w-11",
              @page_number < @total_pages &&
                "cursor-pointer bg-theme-surface text-theme-on-surface hover:bg-theme-primary hover:text-theme-on-primary",
              @page_number >= @total_pages && "cursor-not-allowed opacity-50 bg-theme-surface text-theme-on-surface-muted"
            ]}
            phx-click={@page_number < @total_pages && "page_change"}
            phx-value-direction="inc"
          >
            <.icon name="hero-chevron-right" class="h-4 w-4" />
          </button>
        </li>
      </ul>
    </nav>
    """
  end
end
