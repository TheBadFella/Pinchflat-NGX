defmodule PinchflatWeb.CustomComponents.ButtonComponents do
  @moduledoc false
  use Phoenix.Component, global_prefixes: ~w(x-)

  alias PinchflatWeb.CoreComponents
  alias PinchflatWeb.CustomComponents.TextComponents

  @doc """
  Render a button or button-styled navigation link adhering to the 44px standard sizing contract.

  ## Examples

      <.button>
        Save
      </.button>

      <.button variant="outline" href={~p"/sources"}>
        Cancel
      </.button>
  """
  attr :variant, :string,
    default: "primary",
    values: ["primary", "secondary", "outline", "danger", "danger-solid", "warning", "success"]

  attr :color, :string, default: nil
  attr :size, :string, default: "default", values: ["default", "compact", "large"]
  attr :rounding, :string, default: "rounded-m3-sm"
  attr :class, :any, default: ""
  attr :type, :string, default: "submit"
  attr :disabled, :boolean, default: false
  attr :href, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :method, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :rest, :global, include: ~w(form download target rel)

  slot :inner_block, required: true

  def button(assigns) do
    size_class = button_size_class(assigns.size)
    variant_class = resolve_button_variant(assigns.color, assigns.variant, assigns.class)

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:variant_class, variant_class)

    ~H"""
    <%= if (@href || @navigate || @patch) && !@disabled do %>
      <.link
        href={@href}
        navigate={@navigate}
        patch={@patch}
        method={@method}
        class={[
          "theme-button",
          @size_class,
          @rounding,
          @variant_class,
          @class
        ]}
        aria-disabled={if @disabled, do: "true", else: nil}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
    <% else %>
      <button
        class={[
          "theme-button",
          @size_class,
          @rounding,
          @variant_class,
          @class
        ]}
        type={@type}
        name={@name}
        value={@value}
        disabled={@disabled}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
    <% end %>
    """
  end

  @doc """
  Render a dropdown based off a button adhering to the 44px standard.

  ## Examples

      <.button_dropdown text="Actions">
        <:option>TEST</:option>
      </.button_dropdown>
  """
  attr :text, :string, required: true
  attr :class, :string, default: ""
  attr :variant, :string, default: "primary"
  attr :size, :string, default: "default"

  slot :option, required: true

  def button_dropdown(assigns) do
    size_class = button_size_class(assigns.size)
    variant_class = resolve_button_variant(nil, assigns.variant, assigns.class)

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:variant_class, variant_class)

    ~H"""
    <div
      x-data="{ dropdownOpen: false, openUpwards: false, menuHeight: 480 }"
      x-on:keydown.escape.prevent.stop="dropdownOpen = false; $refs.trigger.focus()"
      class={["relative flex", @class]}
    >
      <button
        x-ref="trigger"
        type="button"
        x-bind:aria-expanded="dropdownOpen"
        x-on:click.prevent="
          const rect = $refs.trigger.getBoundingClientRect();
          const top = Math.max(8, (document.querySelector('header')?.getBoundingClientRect().bottom || 0) + 8);
          const above = Math.max(0, rect.top - top - 8);
          const below = Math.max(0, window.innerHeight - rect.bottom - 16);
          openUpwards = above > below;
          menuHeight = Math.min(480, openUpwards ? above : below);
          dropdownOpen = !dropdownOpen;
        "
        class={[
          "theme-button gap-2.5",
          @size_class,
          @variant_class
        ]}
      >
        {@text}
        <CoreComponents.icon
          name="hero-chevron-down"
          class="h-4 w-4 fill-current duration-200 ease-linear"
          x-bind:class="dropdownOpen && 'rotate-180'"
        />
      </button>

      <div
        x-show="dropdownOpen"
        x-on:click.outside="dropdownOpen = false"
        x-bind:class="openUpwards ? 'bottom-full mb-2' : 'top-full mt-2'"
        x-bind:style="{ maxHeight: menuHeight + 'px' }"
        class="absolute right-0 z-40 min-w-full w-max max-w-[min(18rem,calc(100vw-2rem))] overflow-y-auto rounded-m3-sm border border-theme-outline/80 bg-theme-surface-2 py-2 text-theme-on-surface shadow-m3-2"
      >
        <ul class="flex flex-col">
          <li :for={option <- @option} class="theme-dropdown-option">
            {render_slot(option)}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Render a button with an icon. Optionally include a tooltip.

  ## Examples

      <.icon_button icon_name="hero-check" tooltip="Complete" />
  """
  attr :icon_name, :string, required: true
  attr :class, :string, default: ""
  attr :tooltip, :string, default: nil
  attr :tooltip_position, :string, default: "bottom"
  attr :icon_class, :string, default: nil
  attr :variant, :string, default: "outline", values: ["outline", "primary", "warning", "danger", "danger-solid"]
  attr :size, :string, default: "default", values: ["default", "compact", "large"]
  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :href, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :method, :string, default: nil
  attr :rest, :global

  def icon_button(assigns) do
    size_class = icon_button_size_class(assigns.size)
    {variant_class, default_icon_class} = icon_button_variant(assigns.variant, assigns.class)
    icon_class = assigns.icon_class || default_icon_class

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:variant_class, variant_class)
      |> assign(:resolved_icon_class, icon_class)

    ~H"""
    <TextComponents.tooltip position={@tooltip_position} tooltip={@tooltip} tooltip_class="text-nowrap">
      <%= if (@href || @navigate || @patch) && !@disabled do %>
        <.link
          href={@href}
          navigate={@navigate}
          patch={@patch}
          method={@method}
          class={[
            "theme-icon-button",
            @size_class,
            @variant_class,
            @class
          ]}
          aria-disabled={if @disabled, do: "true", else: nil}
          {@rest}
        >
          <CoreComponents.icon name={@icon_name} class={@resolved_icon_class} />
          <span class="sr-only">{@tooltip}</span>
        </.link>
      <% else %>
        <button
          class={[
            "theme-icon-button",
            @size_class,
            @variant_class,
            @class
          ]}
          type={@type}
          disabled={@disabled}
          {@rest}
        >
          <CoreComponents.icon name={@icon_name} class={@resolved_icon_class} />
          <span class="sr-only">{@tooltip}</span>
        </button>
      <% end %>
    </TextComponents.tooltip>
    """
  end

  defp button_size_class("compact"), do: "theme-button-compact"
  defp button_size_class("large"), do: "theme-button-large"
  defp button_size_class(_), do: ""

  defp icon_button_size_class("compact"), do: "theme-icon-button-compact"
  defp icon_button_size_class("large"), do: "h-11 w-11 min-h-11 min-w-11"
  defp icon_button_size_class(_), do: ""

  defp resolve_button_variant(color, _variant, _class) when is_binary(color) and color != "" do
    color
  end

  defp resolve_button_variant(_color, "outline", _class), do: "theme-outline-button"
  defp resolve_button_variant(_color, "secondary", _class), do: "theme-button-secondary"
  defp resolve_button_variant(_color, "danger", _class), do: "theme-danger-button"
  defp resolve_button_variant(_color, "danger-solid", _class), do: "theme-danger-button-solid"
  defp resolve_button_variant(_color, "warning", _class), do: "theme-warning-button"
  defp resolve_button_variant(_color, "success", _class), do: "theme-success-button"
  defp resolve_button_variant(_color, _variant, _class), do: "theme-primary-button hover:brightness-110"

  defp icon_button_variant("outline", _class), do: {"theme-outline-button", "h-5 w-5 text-theme-on-surface-muted"}
  defp icon_button_variant("primary", _class), do: {"theme-primary-button", "h-5 w-5 text-theme-on-primary"}
  defp icon_button_variant("warning", _class), do: {"theme-warning-button", "h-5 w-5 text-theme-bg"}
  defp icon_button_variant("danger", _class), do: {"theme-danger-button", "h-5 w-5 text-theme-error"}
  defp icon_button_variant("danger-solid", _class), do: {"theme-danger-button-solid", "h-5 w-5 text-theme-on-error"}

  defp icon_button_variant(_variant, class) when is_binary(class) do
    cond do
      String.contains?(class, "theme-primary-button") -> {"", "h-5 w-5 text-theme-on-primary"}
      String.contains?(class, "theme-warning-button") -> {"", "h-5 w-5 text-theme-bg"}
      String.contains?(class, "theme-danger-button-solid") -> {"", "h-5 w-5 text-theme-on-error"}
      String.contains?(class, "theme-danger-button") -> {"", "h-5 w-5 text-theme-error"}
      true -> {"theme-outline-button", "h-5 w-5 text-theme-on-surface-muted"}
    end
  end
end
