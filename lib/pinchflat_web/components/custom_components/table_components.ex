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
  attr :sort_key, :string, default: nil
  attr :sort_direction, :string, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
    attr :sort_key, :string
  end

  def table(assigns) do
    ~H"""
    <div class="overflow-visible rounded-m3-lg bg-theme-surface-1 shadow-m3-1">
      <div class="overflow-x-auto overflow-y-hidden">
        <table class={[
          "min-w-full w-max table-auto text-theme-on-surface",
          @table_class
        ]}>
          <thead>
            <tr class="border-b border-theme-outline/70 bg-theme-surface-3 text-left">
              <th
                :for={col <- @col}
                class={["px-4 py-4 font-medium text-theme-on-surface", col[:sort_key] && "cursor-pointer"]}
                phx-click={col[:sort_key] && "sort_update"}
                phx-value-sort_key={col[:sort_key]}
              >
                <div class="relative">
                  {col[:label]}
                  <.icon
                    :if={to_string(@sort_key) == col[:sort_key]}
                    name={if @sort_direction == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
                    class="w-3 h-3 mt-2 ml-1 absolute"
                  />
                </div>
              </th>
            </tr>
          </thead>

          <tbody class="divide-y divide-theme-outline/60">
            <tr :for={row <- @rows} class="transition hover:bg-theme-surface-2">
              <td
                :for={col <- @col}
                class={[
                  "px-4 py-5 text-theme-on-surface-muted",
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

  @doc """
  Renders simple pagination controls for a table in a liveview.

  ## Examples

      <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
  """
  attr :page_number, :integer, default: 1
  attr :total_pages, :integer, default: 1

  def live_pagination_controls(assigns) do
    ~H"""
    <nav>
      <ul class="flex flex-wrap items-center">
        <li>
          <span
            class={[
              "pagination-prev h-8 w-8 items-center justify-center rounded-m3-xs",
              @page_number != 1 &&
                "cursor-pointer bg-theme-surface text-theme-on-surface transition hover:bg-theme-primary hover:text-theme-on-primary",
              @page_number <= 1 && "cursor-not-allowed opacity-50"
            ]}
            phx-click={@page_number != 1 && "page_change"}
            phx-value-direction="dec"
          >
            <.icon name="hero-chevron-left" />
          </span>
        </li>
        
        <li>
          <span class="mx-2">
            Page <.localized_number number={@page_number} /> of <.localized_number number={@total_pages} />
          </span>
        </li>
        
        <li>
          <span
            class={[
              "pagination-next flex h-8 w-8 items-center justify-center rounded-m3-xs",
              @page_number != @total_pages &&
                "cursor-pointer bg-theme-surface text-theme-on-surface transition hover:bg-theme-primary hover:text-theme-on-primary",
              @page_number >= @total_pages && "cursor-not-allowed opacity-50"
            ]}
            phx-click={@page_number != @total_pages && "page_change"}
            phx-value-direction="inc"
          >
            <.icon name="hero-chevron-right" />
          </span>
        </li>
      </ul>
    </nav>
    """
  end
end
