defmodule PinchflatWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as modals, tables, and
  forms. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The default components use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn
  how to customize them or feel free to swap in another framework altogether.

  Icons are provided by [heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component, global_prefixes: ~w(x-)
  use Gettext, backend: PinchflatWeb.Gettext

  alias Phoenix.LiveView.JS
  alias PinchflatWeb.CustomComponents.TextComponents

  @heroicons_dir Path.expand("../../../assets/vendor/heroicons/optimized", __DIR__)
  @simple_icons_dir Path.expand("../../../assets/vendor/simple-icons", __DIR__)
  @hero_outline_paths Path.wildcard(Path.join(@heroicons_dir, "24/outline/*.svg"))
  @hero_solid_paths Path.wildcard(Path.join(@heroicons_dir, "24/solid/*.svg"))
  @hero_mini_paths Path.wildcard(Path.join(@heroicons_dir, "20/solid/*.svg"))
  @simple_icon_paths Path.wildcard(Path.join(@simple_icons_dir, "*.svg"))
  @icon_paths @hero_outline_paths ++ @hero_solid_paths ++ @hero_mini_paths ++ @simple_icon_paths

  for path <- @icon_paths do
    @external_resource path
  end

  @icon_data_uris (
                    load_data_uri = fn path ->
                      svg =
                        path
                        |> File.read!()
                        |> String.replace(~r/\r?\n/, "")
                        |> String.replace("currentColor", "#000")
                        |> Base.encode64()

                      "url(\"data:image/svg+xml;base64,#{svg}\")"
                    end

                    Enum.into(@hero_outline_paths, %{}, fn path ->
                      {"hero-" <> Path.basename(path, ".svg"), load_data_uri.(path)}
                    end)
                    |> Map.merge(
                      Enum.into(@hero_solid_paths, %{}, fn path ->
                        {"hero-" <> Path.basename(path, ".svg") <> "-solid", load_data_uri.(path)}
                      end)
                    )
                    |> Map.merge(
                      Enum.into(@hero_mini_paths, %{}, fn path ->
                        {"hero-" <> Path.basename(path, ".svg") <> "-mini", load_data_uri.(path)}
                      end)
                    )
                    |> Map.merge(
                      Enum.into(@simple_icon_paths, %{}, fn path ->
                        {"si-" <> Path.basename(path, ".svg"), load_data_uri.(path)}
                      end)
                    )
                  )

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :allow_close, :boolean, default: true
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-99999 hidden"
    >
      <div id={"#{@id}-bg"} class="bg-theme-scrim/80 fixed inset-0 transition-opacity" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-2 sm:p-6 lg:py-8">
            <div
              id={"#{@id}-container"}
              phx-window-keydown={@allow_close && JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={@allow_close && JS.exec("data-cancel", to: "##{@id}")}
              class="theme-surface-raised relative hidden rounded-m3-lg p-8 sm:p-14 transition"
            >
              <div :if={@allow_close} class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-60 hover:opacity-80"
                  aria-label={gettext("close")}
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5 text-theme-on-surface" />
                </button>
              </div>

              <div id={"#{@id}-content"}>{render_slot(@inner_block)}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      class="pb-8"
      role="alert"
      {@rest}
    >
      <div class={[
        "flex justify-between w-full rounded-m3-sm border-l-4 p-5 shadow-m3-1",
        @kind == :info && "border-theme-success bg-theme-success/15 text-theme-on-surface",
        @kind == :error && "border-theme-error bg-theme-error/15 text-theme-on-surface"
      ]}>
        <main>
          <h5 :if={@title} class="mb-2 text-lg font-bold">{@title}</h5>

          <p class="mt-2 text-md leading-5 opacity-80">{msg}</p>
        </main>

        <button
          type="button"
          aria-label={gettext("close")}
          phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
        >
          <.icon name="hero-x-mark-solid" class="h-7 w-7 opacity-70 hover:opacity-100" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div class="flex flex-col gap-7.5" id={@id}>
      <.flash kind={:info} title="Success!" flash={@flash} /> <.flash kind={:error} title="Error!" flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Hang in there while we get back on track <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      {render_slot(@inner_block, f)}
      <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">{render_slot(action, f)}</div>
    </.form>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :label_suffix, :string, default: nil
  attr :value, :any
  attr :help, :string, default: nil
  attr :html_help, :boolean, default: false

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
            checkbox_group toggle range radio search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField, doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :inputclass, :string, default: ""

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :inner_block
  slot :input_append

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(
      :errors,
      if(Phoenix.Component.used_input?(field), do: Enum.map(field.errors, &translate_error(&1)), else: [])
    )
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label class="flex items-center gap-4 text-sm leading-6">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={["rounded border-theme-outline bg-theme-surface-2 text-theme-primary focus:ring-0", @inputclass]}
          {@rest}
        /> {@label} <span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </label>
      <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "checkbox_group"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>
        {@label}<span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </.label>

      <section class="grid grid-cols-1 gap-2 md:grid-cols-2 max-w-prose mb-4 ml-1">
        <div :for={{option_name, option_value} <- @options} class="flex items-center">
          <input
            type="checkbox"
            id={"#{@id}-#{option_value}"}
            name={"#{@name}[]"}
            value={option_value}
            checked={option_value in @value}
            class={[
              "h-5 w-5 rounded border-theme-outline bg-theme-surface-2 text-theme-primary ring-offset-0 focus:ring-0 focus:ring-offset-0",
              @inputclass
            ]}
          /> <label for={"#{@id}-#{option_value}"} class="ml-2 cursor-pointer select-none">{option_name}</label>
        </div>
      </section>

      <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "toggle"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div id={"#{@id}-wrapper"}>
      <.label :if={@label} for={@id}>
        {@label} <span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </.label>

      <div class="flex flex-col">
        <label for={@id} class="relative inline-flex w-fit cursor-pointer items-center">
          <input type="hidden" name={@name} value="false" />
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class="peer sr-only"
            {@rest}
          />
          <div class="block h-8 w-14 rounded-full border border-theme-outline bg-theme-surface-5 shadow-inner transition peer-checked:border-theme-primary/70 peer-checked:bg-theme-primary-container peer-disabled:opacity-50">
          </div>

          <div class={[
            "absolute left-1 top-1 flex h-6 w-6 items-center justify-center rounded-full bg-theme-on-surface-muted shadow-m3-1 transition peer-checked:translate-x-6 peer-checked:bg-theme-primary peer-disabled:opacity-80",
            @inputclass
          ]}>
          </div>
        </label>
        <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns =
      assigns
      |> assign(:select_options, normalize_select_options(assigns.options || []))
      |> assign(:prompt_option, prompt_option(assigns.prompt))
      |> assign(:select_options_json, Phoenix.json_library().encode!(normalize_select_options(assigns.options || [])))
      |> assign(:prompt_json, Phoenix.json_library().encode!(assigns.prompt || ""))
      |> assign(:rest_disabled, rest_attr(assigns.rest, "disabled"))
      |> assign(:rest_x_bind_disabled, rest_attr(assigns.rest, "x-bind:disabled"))

    if assigns.multiple do
      render_native_select(assigns)
    else
      render_custom_select(assigns)
    end
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>
        {@label}<span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </.label>

      <div class="theme-field-shell mt-2">
        <textarea
          id={@id}
          name={@name}
          class={[
            "theme-input block min-h-[6rem] w-full rounded-m3-sm px-5 py-3 focus:ring-0 sm:text-sm sm:leading-6",
            @inputclass
          ]}
          {@rest}
        ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      </div>

      <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div>
      <.label for={@id}>
        {@label}<span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </.label>

      <div class="flex items-center">
        <div class="theme-field-shell">
          <input
            type={@type}
            name={@name}
            id={@id}
            value={Phoenix.HTML.Form.normalize_value(@type, @value)}
            class={[
              "theme-input w-full rounded-m3-sm px-5 py-3 font-normal",
              "outline-none transition disabled:cursor-default disabled:opacity-50",
              @inputclass
            ]}
            {@rest}
          />
        </div>
        {render_slot(@input_append)}
      </div>

      <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp render_native_select(assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>
        {@label}<span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </.label>

      <div class="flex">
        <div class="theme-field-shell">
          <select
            id={@id}
            name={@name}
            class={[
              "theme-input theme-select relative z-20 w-full appearance-none rounded-m3-sm py-3 pl-5 pr-12 outline-none transition",
              "disabled:cursor-not-allowed disabled:opacity-50",
              @inputclass
            ]}
            multiple={@multiple}
            {@rest}
          >
            <option :if={@prompt} value="">{@prompt}</option>
            {Phoenix.HTML.Form.options_for_select(@options, @value)}
          </select>
        </div>
        {render_slot(@inner_block)}
      </div>

      <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp render_custom_select(assigns) do
    custom_select_data = """
    {
      open: false,
      options: #{assigns.select_options_json},
      prompt: #{assigns.prompt_json},
      selectedValue: '',
      selectedLabel: '',
      syncFromInput() {
        this.selectedValue = `${this.$refs.input.value ?? ''}`
        const match = this.options.find(option => option.value === this.selectedValue)
        this.selectedLabel = match ? match.label : ''
      },
      selectOption(value) {
        this.$refs.input.value = value
        this.syncFromInput()
        this.open = false
        this.$refs.input.dispatchEvent(new Event('input', { bubbles: true }))
        this.$refs.input.dispatchEvent(new Event('change', { bubbles: true }))
      },
      init() {
        this.syncFromInput()
      }
    }
    """

    assigns = assign(assigns, :custom_select_data, custom_select_data)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>
        {@label}<span :if={@label_suffix} class="text-xs text-theme-on-surface-muted">{@label_suffix}</span>
      </.label>

      <div class="flex">
        <div
          class="theme-field-shell relative w-full isolate"
          x-data={@custom_select_data}
          x-init="init()"
          x-on:click.outside="open = false"
          x-bind:class="open ? 'theme-field-shell-active z-[90]' : 'z-10'"
        >
          <input
            x-ref="input"
            type="hidden"
            id={@id}
            name={@name}
            value={@value}
            {@rest}
            x-on:input="syncFromInput()"
            x-on:change="syncFromInput()"
          />
          <button
            type="button"
            class={[
              "theme-input flex w-full items-center justify-between gap-3 rounded-m3-sm px-5 py-3 text-left outline-none transition",
              "disabled:cursor-not-allowed disabled:opacity-50",
              @inputclass
            ]}
            x-on:click="open = !open"
            x-on:keydown.escape.prevent="open = false"
            x-bind:aria-expanded="open"
            aria-haspopup="listbox"
            aria-controls={"#{@id}-options"}
            x-bind:disabled={@rest_x_bind_disabled}
            disabled={@rest_disabled}
          >
            <span
              class="truncate"
              x-bind:class="selectedLabel ? 'text-theme-on-surface' : 'text-theme-on-surface-muted'"
              x-text="selectedLabel || prompt"
            >
            </span>
            <.icon
              name="hero-chevron-down"
              class="h-5 w-5 shrink-0 text-theme-on-surface-muted transition duration-200"
              x-bind:class="open ? 'rotate-180 text-theme-primary' : ''"
            />
          </button>
          <div
            x-cloak
            x-show="open"
            x-transition.origin.top.left.duration.120ms
            id={"#{@id}-options"}
            class="theme-select-menu absolute left-0 top-full z-[100] mt-2 max-h-72 w-full overflow-y-auto p-2"
            role="listbox"
          >
            <button
              :if={@prompt_option}
              type="button"
              class="theme-select-option flex w-full items-center rounded-m3-sm px-4 py-3 text-left text-sm transition hover:border-theme-outline hover:bg-theme-surface-3 hover:text-theme-on-surface"
              x-bind:class="selectedValue === '' ? 'bg-theme-primary-container text-theme-on-primary-container' : 'theme-select-option-muted'"
              x-on:click="selectOption('')"
            >
              {@prompt_option.label}
            </button>
            <button
              :for={option <- @select_options}
              type="button"
              data-value={option.value}
              class="theme-select-option flex w-full items-center justify-between gap-3 rounded-m3-sm px-4 py-3 text-left text-sm transition hover:border-theme-outline hover:bg-theme-surface-3 hover:text-theme-on-surface"
              x-bind:class={"selectedValue === '#{option.value}' ? 'bg-theme-primary-container text-theme-on-primary-container' : 'theme-select-option-muted'"}
              x-on:click="selectOption($el.dataset.value)"
            >
              <span class="truncate">{option.label}</span>
              <.icon
                name="hero-check"
                class="h-4 w-4 shrink-0 text-theme-primary"
                x-show={"selectedValue === '#{option.value}'"}
              />
            </button>
          </div>
        </div>
        {render_slot(@inner_block)}
      </div>

      <.help :if={@help}>{if @html_help, do: Phoenix.HTML.raw(@help), else: @help}</.help>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders help text.
  """
  slot :inner_block, required: true

  def help(assigns) do
    ~H"""
    <p class="mt-1 text-sm leading-5 text-theme-on-surface-muted">{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="mt-5 mb-2 inline-block text-md font-medium text-theme-on-surface">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 mb-5 flex gap-3 text-md leading-6 text-theme-error">
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" /> {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def old_header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-theme-on-surface">{render_slot(@inner_block)}</h1>

        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-theme-on-surface-muted">{render_slot(@subtitle)}</p>
      </div>

      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.old_table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
      </.old_table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def old_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-[40rem] mt-11 sm:w-full">
      <thead class="text-sm text-left leading-6 text-theme-on-surface-muted">
        <tr>
          <th :for={col <- @col} class="p-0 pb-4 pr-6 font-normal">{col[:label]}</th>

          <th :if={@action != []} class="relative p-0 pb-4"><span class="sr-only">{gettext("Actions")}</span></th>
        </tr>
      </thead>

      <tbody
        id={@id}
        phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
        class="relative divide-y divide-theme-outline/60 border-t border-theme-outline/70 text-sm leading-6 text-theme-on-surface"
      >
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group transition hover:bg-theme-surface-2">
          <td
            :for={{col, i} <- Enum.with_index(@col)}
            phx-click={@row_click && @row_click.(row)}
            class={["relative p-0", @row_click && "hover:cursor-pointer"]}
          >
            <div class="block py-4 pr-6">
              <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-theme-surface-2 sm:rounded-l-xl" />
              <span class={["relative", i == 0 && "font-semibold text-theme-on-surface"]}>
                {render_slot(col, @row_item.(row))}
              </span>
            </div>
          </td>

          <td :if={@action != []} class="relative w-14 p-0">
            <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
              <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-theme-surface-2 sm:rounded-r-xl" />
              <span
                :for={action <- @action}
                class="relative ml-4 font-semibold leading-6 text-theme-on-surface hover:text-theme-primary"
              >
                {render_slot(action, @row_item.(row))}
              </span>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title"><%= @post.title %></:item>
        <:item title="Views"><%= @post.views %></:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <div class="mt-2 mb-14">
      <dl class="-my-4 divide-y divide-theme-outline/70">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-theme-on-surface">{item.title}</dt>

          <dd class="text-theme-on-surface">{render_slot(item)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a data list from a given map. Used in development to
  quickly show the attributes of a database record.
  """
  attr :map, :map, required: true

  def list_items_from_map(assigns) do
    attrs =
      Enum.filter(assigns.map, fn
        {_, %{__struct__: s}} when s not in [Date, DateTime] ->
          false

        {_, [%{__meta__: _} | _]} ->
          false

        _ ->
          true
      end)
      |> Enum.map(fn
        {k, v} when is_list(v) -> {k, Enum.join(v, ", ")}
        rest -> rest
      end)

    assigns = assign(assigns, iterable_attributes: attrs)

    ~H"""
    <ul>
      <li :for={{k, v} <- @iterable_attributes} class="mb-2 w-2/3">
        <strong>{k}:</strong>
        <code class="mx-0.5 inline-block p-0.5 font-mono text-sm text-theme-on-surface-muted">
          <%= if is_binary(v) && URI.parse(v).scheme && URI.parse(v).scheme =~ "http" do %>
            <TextComponents.inline_link href={v}>{v}</TextComponents.inline_link>
          <% else %>
            {v}
          <% end %>
        </code>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back href={~p"/posts"}>Back to posts</.back>
  """
  attr :href, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link href={@href} class="text-sm font-semibold leading-6 text-theme-on-surface transition hover:text-theme-primary">
        <.icon name="hero-arrow-left-solid" class="h-3 w-3" /> {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are loaded from `assets/vendor/heroicons` and `assets/vendor/simple-icons`
  and rendered with CSS masks, so they no longer depend on Tailwind plugin-generated classes.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  def icon(assigns) do
    assigns =
      assign(assigns, :style_attr, icon_style(assigns.name))

    ~H"""
    <span class={["h-5 w-5", @class, "inline-block align-middle"]} data-icon={@name} style={@style_attr} {@rest} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition: {
        "transition-all transform ease-out duration-300",
        "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
        "opacity-100 translate-y-0 sm:scale-100"
      }
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition: {
        "transition-all transform ease-in duration-200",
        "opacity-100 translate-y-0 sm:scale-100",
        "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"
      }
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(PinchflatWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PinchflatWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  defp normalize_select_options(options) do
    Enum.map(options, fn
      {label, value} -> %{label: to_string(label), value: to_string(value)}
      label -> %{label: to_string(label), value: to_string(label)}
    end)
  end

  defp prompt_option(nil), do: nil
  defp prompt_option(prompt), do: %{label: prompt}

  defp rest_attr(rest, attr_name) do
    Enum.find_value(rest, fn
      {^attr_name, value} ->
        value

      {key, value} ->
        if is_atom(key) and Atom.to_string(key) == attr_name, do: value

      _ ->
        nil
    end)
  end

  defp icon_style(name) do
    data_uri = icon_data_uri(name)

    Enum.join(
      [
        "display:inline-block",
        "vertical-align:middle",
        "background-color:currentColor",
        "-webkit-mask-repeat:no-repeat",
        "mask-repeat:no-repeat",
        "-webkit-mask-position:center",
        "mask-position:center",
        "-webkit-mask-size:contain",
        "mask-size:contain",
        "-webkit-mask-image:#{data_uri}",
        "mask-image:#{data_uri}"
      ],
      ";"
    )
  end

  defp icon_data_uri(name) do
    case Map.fetch(@icon_data_uris, name) do
      {:ok, data_uri} -> data_uri
      :error -> raise ArgumentError, "unknown icon #{inspect(name)}"
    end
  end
end
