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
    initially_selected =
      Enum.any?(
        assigns[:submenu],
        &active_sidebar_path?(assigns[:current_path], to_string(&1[:href]))
      )

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
          "theme-sidebar-item theme-sidebar-submenu-trigger group relative flex min-h-10 items-center rounded-m3-sm border duration-300 ease-in-out lg:min-h-11",
          "duration-300 ease-in-out",
          if(
            @initially_selected,
            do: "theme-sidebar-active",
            else: "border-transparent hover:bg-theme-surface-3"
          )
        ]}
        x-bind:class={"(isSidebarSubmenuActive(#{@submenu_hrefs}) ? 'theme-sidebar-active' : 'border-transparent hover:bg-theme-surface-3')"}
        x-on:click="if (sidebarCollapsed) { sidebarCollapsed = false; window.setSidebarCollapsed(false) } else { selected = !selected }"
      >
        <span class="theme-sidebar-submenu-label flex items-center gap-2.5">
          <.icon
            name={@icon}
            class="theme-sidebar-item-icon shrink-0"
          /> <span class="theme-sidebar-desktop-label">{@text}</span>
        </span>

        <span class="theme-sidebar-desktop-label text-theme-on-surface-muted">
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

      <ul
        x-show="selected && !sidebarCollapsed"
        style={if !@initially_selected, do: "display: none"}
        class="theme-sidebar-submenu mt-2 ml-5 flex flex-col gap-1 border-l border-theme-outline/60 pl-4"
      >
        <li :for={menu <- @submenu} class="text-theme-on-surface-muted">
          <.sidebar_link
            icon={menu[:icon]}
            text={menu[:text]}
            href={menu[:href]}
            target={menu[:target]}
            current_path={@current_path}
            class="min-h-9 border-transparent pl-4 text-sm"
          />
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
        "theme-sidebar-item group relative flex min-h-10 items-center gap-2 rounded-m3-sm border duration-300 ease-in-out lg:min-h-11 lg:gap-2.5",
        "duration-300 ease-in-out",
        if(
          @active?,
          do: "theme-sidebar-active",
          else: "border-transparent hover:bg-theme-surface-3"
        ),
        @class
      ]}
      x-bind:aria-current={"isSidebarPathActive(#{@href_json}) ? 'page' : null"}
      x-bind:class={"(isSidebarPathActive(#{@href_json}) ? 'theme-sidebar-active' : 'border-transparent hover:bg-theme-surface-3')"}
    >
      <.icon
        :if={@icon}
        name={@icon}
        class={"theme-sidebar-item-icon shrink-0 #{@icon_class}"}
      /> <span class="theme-sidebar-desktop-label">{@text}</span>
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
