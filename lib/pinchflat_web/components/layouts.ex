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
  attr :current_path, :string, default: nil

  def sidebar_item(assigns) do
    ~H"""
    <li class="text-theme-on-surface">
      <.sidebar_link
        icon={@icon}
        text={@text}
        href={@href}
        target={@target}
        icon_class={@icon_class}
        current_path={@current_path}
      />
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

    submenu_hrefs =
      assigns[:submenu]
      |> Enum.map(&to_string(&1[:href]))
      |> Phoenix.json_library().encode!()

    assigns =
      assigns
      |> Map.put(:initially_selected, initially_selected)
      |> Map.put(:submenu_hrefs, submenu_hrefs)

    ~H"""
    <li class="text-theme-on-surface" x-data={"{ selected: #{@initially_selected} }"}>
      <span
        class={[
          "font-medium cursor-pointer",
          "group relative flex min-h-10 items-center justify-between rounded-m3-sm border px-3 py-2 duration-300 ease-in-out lg:min-h-11 lg:px-4",
          "duration-300 ease-in-out lg:px-4",
          if(
            @initially_selected,
            do: "theme-sidebar-active",
            else: "border-transparent hover:bg-theme-surface-3"
          )
        ]}
        x-bind:class={"(sidebarCollapsed ? 'lg:mx-auto lg:h-12 lg:w-12 lg:justify-center lg:rounded-xl lg:px-0' : '') + ' ' + (isSidebarSubmenuActive(#{@submenu_hrefs}) ? 'theme-sidebar-active' : 'border-transparent hover:bg-theme-surface-3')"}
        x-on:click="if (sidebarCollapsed) { sidebarCollapsed = false; window.setSidebarCollapsed(false) } else { selected = !selected }"
      >
        <span class="flex items-center gap-2.5" x-bind:class="sidebarCollapsed ? 'lg:justify-center' : ''">
          <.icon
            name={@icon}
            class="h-5 w-5 shrink-0"
            x-bind:class="sidebarCollapsed ? 'lg:h-[1.625rem] lg:w-[1.625rem]' : ''"
          /> <span x-bind:class="sidebarCollapsed ? 'lg:hidden' : ''">{@text}</span>
        </span>
        <span class="text-theme-on-surface-muted" x-bind:class="sidebarCollapsed ? 'lg:hidden' : ''">
          <.icon name="hero-chevron-down" x-bind:class="{ 'rotate-180': selected }" />
        </span>
        <span
          x-cloak
          x-show="sidebarCollapsed"
          class="pointer-events-none absolute top-1/2 z-[10000] hidden -translate-y-1/2 whitespace-nowrap rounded-m3-xs border border-theme-outline/80 bg-theme-surface-3 px-2 py-1 text-sm text-theme-on-surface opacity-0 shadow-m3-2 transition duration-150 group-hover:opacity-100 lg:block"
          style="left: calc(100% + 0.75rem);"
        >
          {@text}
        </span>
      </span>
      <ul x-cloak x-show="selected && !sidebarCollapsed">
        <li :for={menu <- @submenu} class="text-theme-on-surface-muted">
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
  attr :current_path, :string, default: nil

  def sidebar_link(assigns) do
    href = to_string(assigns.href)

    assigns =
      assigns
      |> assign(:active?, active_sidebar_path?(assigns.current_path, href))
      |> assign(:href_json, Phoenix.json_library().encode!(href))

    ~H"""
    <.link
      href={@href}
      target={@target}
      aria-current={if @active?, do: "page", else: nil}
      class={[
        "font-medium",
        "group relative flex min-h-10 items-center gap-2 rounded-m3-sm border px-3 py-2 duration-300 ease-in-out lg:min-h-11 lg:gap-2.5 lg:px-4",
        "duration-300 ease-in-out",
        if(
          @active?,
          do: "theme-sidebar-active",
          else: "border-transparent hover:bg-theme-surface-3"
        ),
        @class
      ]}
      x-bind:aria-current={"isSidebarPathActive(#{@href_json}) ? 'page' : null"}
      x-bind:class={"(sidebarCollapsed ? 'lg:mx-auto lg:h-12 lg:w-12 lg:justify-center lg:rounded-xl lg:px-0' : '') + ' ' + (isSidebarPathActive(#{@href_json}) ? 'theme-sidebar-active' : 'border-transparent hover:bg-theme-surface-3')"}
    >
      <.icon
        :if={@icon}
        name={@icon}
        class={"h-5 w-5 shrink-0 #{@icon_class}"}
        x-bind:class="sidebarCollapsed ? 'lg:h-[1.625rem] lg:w-[1.625rem]' : ''"
      /> <span x-bind:class="sidebarCollapsed ? 'lg:hidden' : ''">{@text}</span>
      <span
        x-cloak
        x-show="sidebarCollapsed"
        class="pointer-events-none absolute top-1/2 z-[10000] hidden -translate-y-1/2 whitespace-nowrap rounded-m3-xs border border-theme-outline/80 bg-theme-surface-3 px-2 py-1 text-sm text-theme-on-surface opacity-0 shadow-m3-2 transition duration-150 group-hover:opacity-100 lg:block"
        style="left: calc(100% + 0.75rem);"
      >
        {@text}
      </span>
    </.link>
    """
  end

  defp active_sidebar_path?(nil, _href), do: false

  defp active_sidebar_path?(current_path, href) when is_binary(current_path) and is_binary(href) do
    cond do
      href == "/" ->
        current_path == "/"

      current_path == href ->
        true

      String.starts_with?(current_path, href <> "/") ->
        true

      true ->
        false
    end
  end

  defp active_sidebar_path?(_current_path, _href), do: false
end
