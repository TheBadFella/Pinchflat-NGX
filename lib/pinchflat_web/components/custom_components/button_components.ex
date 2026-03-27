defmodule PinchflatWeb.CustomComponents.ButtonComponents do
  @moduledoc false
  use Phoenix.Component, global_prefixes: ~w(x-)

  alias PinchflatWeb.CoreComponents
  alias PinchflatWeb.CustomComponents.TextComponents

  @doc """
  Render a button

  ## Examples

      <.button color="bg-primary" rounding="rounded-sm">
        <span>Click me</span>
      </.button>
  """
  attr :color, :string, default: "bg-theme-primary text-theme-on-primary"
  attr :rounding, :string, default: "rounded-m3-sm"
  attr :class, :string, default: ""
  attr :type, :string, default: "submit"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      class={[
        "text-center font-medium whitespace-nowrap transition shadow-m3-1",
        "#{@rounding} inline-flex items-center justify-center px-8 py-4",
        "#{@color}",
        "hover:brightness-110 lg:px-8 xl:px-10",
        "disabled:cursor-not-allowed disabled:opacity-50",
        @class
      ]}
      type={@type}
      disabled={@disabled}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Render a dropdown based off a button

  ## Examples

      <.button_dropdown text="Actions">
        <:option>TEST</:option>
      </.button_dropdown>
  """
  attr :text, :string, required: true
  attr :class, :string, default: ""

  slot :option, required: true

  def button_dropdown(assigns) do
    ~H"""
    <div x-data="{ dropdownOpen: false }" class={["relative flex", @class]}>
      <span
        x-on:click.prevent="dropdownOpen = !dropdownOpen"
        class={[
          "cursor-pointer inline-flex gap-2.5 rounded-m3-sm bg-theme-primary px-5.5 py-3",
          "font-medium text-theme-on-primary shadow-m3-1 transition hover:brightness-110"
        ]}
      >
        {@text}
        <CoreComponents.icon
          name="hero-chevron-down"
          class="fill-current duration-200 ease-linear mt-1"
          x-bind:class="dropdownOpen && 'rotate-180'"
        />
      </span>
      <div
        x-show="dropdownOpen"
        x-on:click.outside="dropdownOpen = false"
        class="absolute left-0 top-full z-40 mt-2 w-full rounded-m3-sm border border-theme-outline/80 bg-theme-surface-2 py-3 text-theme-on-surface shadow-m3-2"
      >
        <ul class="flex flex-col">
          <li :for={option <- @option}>
            <span class="flex cursor-pointer px-5 py-2 font-medium text-theme-on-surface-muted transition hover:bg-theme-surface-3 hover:text-theme-on-surface">
              {render_slot(option)}
            </span>
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
  attr :type, :string, default: "button"
  attr :rest, :global

  def icon_button(assigns) do
    {variant_class, default_icon_class} = icon_button_variant(assigns.variant, assigns.class)
    icon_class = assigns.icon_class || default_icon_class

    assigns =
      assigns
      |> assign(:variant_class, variant_class)
      |> assign(:resolved_icon_class, icon_class)

    ~H"""
    <TextComponents.tooltip position={@tooltip_position} tooltip={@tooltip} tooltip_class="text-nowrap">
      <button
        class={[
          "flex items-center justify-center rounded-m3-sm border-2 transition-colors",
          @variant_class,
          @class
        ]}
        type={@type}
        {@rest}
      >
        <CoreComponents.icon name={@icon_name} class={@resolved_icon_class} />
      </button>
    </TextComponents.tooltip>
    """
  end

  defp icon_button_variant("outline", _class), do: {"theme-outline-button", "text-theme-on-surface-muted"}
  defp icon_button_variant("primary", _class), do: {"theme-primary-button", "text-theme-on-primary"}
  defp icon_button_variant("warning", _class), do: {"theme-warning-button", "text-theme-bg"}
  defp icon_button_variant("danger", _class), do: {"theme-danger-button", "text-theme-error"}
  defp icon_button_variant("danger-solid", _class), do: {"theme-danger-button-solid", "text-theme-on-error"}

  defp icon_button_variant(_variant, class) when is_binary(class) do
    cond do
      String.contains?(class, "theme-primary-button") -> {"", "text-theme-on-primary"}
      String.contains?(class, "theme-warning-button") -> {"", "text-theme-bg"}
      String.contains?(class, "theme-danger-button-solid") -> {"", "text-theme-on-error"}
      String.contains?(class, "theme-danger-button") -> {"", "text-theme-error"}
      true -> {"theme-outline-button", "text-theme-on-surface-muted"}
    end
  end
end
