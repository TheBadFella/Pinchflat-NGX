defmodule PinchflatWeb.CustomComponents.SettingsNavComponents do
  @moduledoc """
  Navigation for the long settings forms (source, media profile, Settings).

  The components here render the markup; `window.settingsNav()` in
  `assets/js/alpine_helpers.js` holds the behaviour and documents the
  `data-settings` / `data-setting` / `data-setting-group` contract. The page's
  Alpine root must be `x-data="settingsNav()"` (or an object built on it).
  """

  use Phoenix.Component, global_prefixes: ~w(x-)

  import PinchflatWeb.CoreComponents, only: [icon: 1, input: 1]

  @doc """
  The "Find a setting" field plus the section list: a sticky rail on `lg` and
  up, a sticky chip row below. On wide screens the section being read lists its
  settings as links that scroll to and focus the field.

  `sections` is a list of `{section_id, title}`. `bleed` holds
  the classes that let the chip row span its container's padding on small
  screens; the default fits a form inside a raised card.
  """
  attr :label, :string, required: true, doc: "accessible name of the section list"
  attr :sections, :list, required: true
  attr :placeholder, :string, default: nil
  attr :bleed, :string, default: "-mx-5 bg-theme-surface-2 px-5 sm:-mx-7.5 sm:px-7.5"

  def settings_nav(assigns) do
    ~H"""
    <div class="contents lg:sticky lg:top-24 lg:block lg:self-start">
      <.input
        type="search"
        name="setting_search"
        id="setting-search"
        value=""
        label="Find a setting"
        placeholder={@placeholder}
        autocomplete="off"
        x-model="settingQuery"
        x-on:keydown.enter.prevent
      />
      <nav
        aria-label={@label}
        class={[
          "sticky top-20 z-10 mt-3 flex gap-1 overflow-x-auto border-b border-theme-outline/60 py-2",
          "lg:static lg:mx-0 lg:flex-col lg:overflow-visible lg:border-0 lg:bg-transparent lg:p-0",
          @bleed
        ]}
      >
        <div :for={{id, title} <- @sections} class="contents lg:block">
          <a
            href={"##{id}"}
            x-on:click={"showSection('#{id}')"}
            x-bind:aria-current={"activeSection === '#{id}' ? 'true' : false"}
            x-bind:class={"activeSection === '#{id}' ? 'theme-nav-current' : 'text-theme-on-surface-muted'"}
            class="theme-filter-button shrink-0 rounded-full hover:bg-theme-surface-3 hover:text-theme-on-surface lg:w-full lg:justify-start"
          >
            {title}
          </a>
          <%!-- Settings of the section being read. Wide screens only: the phone row has no room for them. --%>
          <ul
            x-cloak
            x-show={"activeSection === '#{id}'"}
            aria-label={"Settings in #{title}"}
            class="hidden border-l border-theme-outline/60 py-1 lg:ml-5 lg:block"
          >
            <template x-for={"item in sectionSettings['#{id}'] || []"} x-bind:key="item.target">
              <li>
                <a
                  x-bind:href="'#' + item.target"
                  x-text="item.title"
                  x-on:click.prevent="goToSetting(item.target)"
                  x-bind:aria-current="activeSetting === item.target ? 'true' : false"
                  x-bind:class="activeSetting === item.target && 'theme-nav-current'"
                  class="block rounded-m3-sm px-3 py-1.5 text-xs leading-snug text-theme-on-surface-muted hover:bg-theme-surface-3 hover:text-theme-on-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70 lg:whitespace-normal lg:[overflow-wrap:anywhere]"
                ></a>
              </li>
            </template>
          </ul>
        </div>
      </nav>
    </div>
    """
  end

  @doc """
  Shown in place of the settings when the "Find a setting" query matches nothing.
  """
  attr :class, :string, default: "mt-6"

  def settings_no_match(assigns) do
    ~H"""
    <p x-cloak x-show="settingQuery.trim() && settingMatches === 0" class={["text-sm text-theme-on-surface-muted", @class]}>
      No settings match "<span x-text="settingQuery.trim()"></span>". Try a shorter word, or clear the search to see every setting.
    </p>
    """
  end

  @doc """
  A collapsed group of settings or help text. The optional status slot shows
  the current value so a closed group still says what is set.
  """
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  attr :rest, :global

  slot :status
  slot :inner_block, required: true

  def form_disclosure(assigns) do
    ~H"""
    <details class="group theme-surface-accent mt-4 px-5" open={@open} {@rest}>
      <summary class="flex min-h-11 cursor-pointer list-none items-center gap-3 rounded-m3-sm py-3 text-sm font-medium text-theme-on-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-theme-primary/70 [&::-webkit-details-marker]:hidden">
        <span class="flex min-w-0 flex-1 flex-col sm:flex-row sm:items-center sm:justify-between sm:gap-3">
          <span>{@title}</span>
          <span :if={@status != []} class="truncate font-normal text-theme-on-surface-muted">
            {render_slot(@status)}
          </span>
        </span>
        <.icon
          name="hero-chevron-down"
          class="h-5 w-5 shrink-0 text-theme-on-surface-muted transition group-open:rotate-180"
        />
      </summary>

      <div class="border-t border-theme-outline/60 pb-5 pt-1">{render_slot(@inner_block)}</div>
    </details>
    """
  end
end
