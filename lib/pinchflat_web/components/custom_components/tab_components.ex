defmodule PinchflatWeb.CustomComponents.TabComponents do
  @moduledoc false
  use Phoenix.Component

  @doc """
  Takes a list of tabs and renders them in a tabbed layout.
  """
  attr :active_tab, :string, default: nil
  attr :tab_href, :any, default: nil

  slot :tab, required: true do
    attr :id, :string, required: true
    attr :title, :string, required: true
  end

  slot :tab_append, required: false

  def tabbed_layout(assigns) do
    first_tab_id = hd(assigns.tab).id

    active_tab_id =
      if Enum.any?(assigns.tab, &(&1.id == assigns.active_tab)), do: assigns.active_tab, else: first_tab_id

    active_tab = Enum.find(assigns.tab, &(&1.id == active_tab_id))

    assigns =
      assigns
      |> assign(:active_tab, active_tab)
      |> assign(:active_tab_id, active_tab_id)

    ~H"""
    <div class="w-full">
      <header class="flex items-end justify-between gap-4 border-b border-theme-outline/70">
        <div class="no-scrollbar flex min-w-0 flex-1 flex-nowrap gap-5 overflow-x-auto sm:gap-8">
          <.link
            :for={tab <- @tab}
            href={tab_href(@tab_href, tab.id)}
            class={[
              "shrink-0 border-b-2 py-4 text-sm font-medium transition md:text-base",
              "text-theme-on-surface-muted hover:text-theme-on-surface",
              if(tab.id == @active_tab_id,
                do: "border-theme-primary text-theme-primary",
                else: "border-transparent"
              )
            ]}
          >
            <span>{tab.title}</span>
          </.link>
        </div>

        <div :if={@tab_append != []} class="flex shrink-0 items-center justify-end gap-3 pb-3">
          {render_slot(@tab_append)}
        </div>
      </header>

      <div class="mt-4 min-h-60 overflow-x-auto">
        <div :if={@active_tab} class="font-medium leading-relaxed">{render_slot(@active_tab)}</div>
      </div>
    </div>
    """
  end

  defp tab_href(nil, _tab_id), do: "#"
  defp tab_href(tab_href, tab_id) when is_function(tab_href, 1), do: tab_href.(tab_id)
end
