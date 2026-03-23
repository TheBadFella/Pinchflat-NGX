defmodule PinchflatWeb.Layouts do
  use PinchflatWeb, :html

  embed_templates "layouts/*"
  embed_templates "layouts/partials/*"

  @doc """
  Renders a sidebar menu item link

  ## Examples

      <.sidebar_link icon="hero-home" text="Home" href="/" />
  """
  attr :icon, :string, required: true
  attr :text, :string, required: true
  attr :href, :any, required: true
  attr :target, :any, default: "_self"
  attr :icon_class, :string, default: ""

  def sidebar_item(assigns) do
    ~H"""
    <li class="text-bodydark1">
      <.sidebar_link icon={@icon} text={@text} href={@href} target={@target} icon_class={@icon_class} />
    </li>
    """
  end

  @doc """
  Renders a sidebar menu item with a submenu

  ## Examples

      <.sidebar_submenu icon="hero-home" text="Home" current_path="/">
        <:submenu icon="hero-home" text="Home" href="/" />
      </.sidebar_submenu>
  """

  attr :icon, :string, required: true
  attr :text, :string, required: true
  attr :current_path, :string, required: true

  slot :submenu do
    attr :icon, :string
    attr :text, :string
    attr :href, :any
    attr :target, :any
  end

  def sidebar_submenu(assigns) do
    initially_selected = Enum.any?(assigns[:submenu], &(&1[:href] == assigns[:current_path]))
    assigns = Map.put(assigns, :initially_selected, initially_selected)

    ~H"""
    <li class="text-bodydark1" x-data={"{ selected: #{@initially_selected} }"}>
      <span
        class={[
          "font-medium cursor-pointer",
          "group relative flex min-h-11 items-center justify-between rounded-sm px-4 py-2 duration-300 ease-in-out",
          "duration-300 ease-in-out lg:px-4",
          "hover:bg-meta-4"
        ]}
        x-bind:class="sidebarCollapsed ? 'lg:mx-auto lg:h-12 lg:w-12 lg:justify-center lg:rounded-xl lg:px-0' : ''"
        x-on:click="if (sidebarCollapsed) { sidebarCollapsed = false; window.setSidebarCollapsed(false) } else { selected = !selected }"
      >
        <span class="flex items-center gap-2.5" x-bind:class="sidebarCollapsed ? 'lg:justify-center' : ''">
          <.icon
            name={@icon}
            class="h-5 w-5 shrink-0"
            x-bind:class="sidebarCollapsed ? 'lg:h-[1.625rem] lg:w-[1.625rem]' : ''"
          /> <span x-bind:class="sidebarCollapsed ? 'lg:hidden' : ''">{@text}</span>
        </span>
        <span class="text-bodydark2" x-bind:class="sidebarCollapsed ? 'lg:hidden' : ''">
          <.icon name="hero-chevron-down" x-bind:class="{ 'rotate-180': selected }" />
        </span>
        <span
          x-cloak
          x-show="sidebarCollapsed"
          class="pointer-events-none absolute top-1/2 z-[10000] hidden -translate-y-1/2 whitespace-nowrap rounded-md bg-slate-950 px-2 py-1 text-sm text-white opacity-0 shadow-2xl ring-1 ring-white/10 transition duration-150 group-hover:opacity-100 lg:block"
          style="left: calc(100% + 0.75rem);"
        >
          {@text}
        </span>
      </span>
      <ul x-cloak x-show="selected && !sidebarCollapsed">
        <li :for={menu <- @submenu} class="text-bodydark2">
          <.sidebar_link icon={menu[:icon]} text={menu[:text]} href={menu[:href]} target={menu[:target]} class="pl-10" />
        </li>
      </ul>
    </li>
    """
  end

  @doc """
  Renders a sidebar menu item link

  ## Examples

      <.sidebar_link icon="hero-home" text="Home" href="/" />
  """
  attr :icon, :string
  attr :text, :string, required: true
  attr :href, :any, required: true
  attr :target, :any, default: "_self"
  attr :class, :string, default: ""
  attr :icon_class, :string, default: ""

  def sidebar_link(assigns) do
    ~H"""
    <.link
      href={@href}
      target={@target}
      class={[
        "font-medium",
        "group relative flex min-h-11 items-center gap-2.5 rounded-sm px-4 py-2 duration-300 ease-in-out",
        "duration-300 ease-in-out",
        "hover:bg-meta-4",
        @class
      ]}
      x-bind:class="sidebarCollapsed ? 'lg:mx-auto lg:h-12 lg:w-12 lg:justify-center lg:rounded-xl lg:px-0' : ''"
    >
      <.icon
        :if={@icon}
        name={@icon}
        class={["h-5 w-5 shrink-0", @icon_class]}
        x-bind:class="sidebarCollapsed ? 'lg:h-[1.625rem] lg:w-[1.625rem]' : ''"
      /> <span x-bind:class="sidebarCollapsed ? 'lg:hidden' : ''">{@text}</span>
      <span
        x-cloak
        x-show="sidebarCollapsed"
        class="pointer-events-none absolute top-1/2 z-[10000] hidden -translate-y-1/2 whitespace-nowrap rounded-md bg-slate-950 px-2 py-1 text-sm text-white opacity-0 shadow-2xl ring-1 ring-white/10 transition duration-150 group-hover:opacity-100 lg:block"
        style="left: calc(100% + 0.75rem);"
      >
        {@text}
      </span>
    </.link>
    """
  end
end
