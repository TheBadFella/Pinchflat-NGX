defmodule PinchflatWeb.CustomComponents.DatePicker do
  @moduledoc """
  A themed calendar with direct ISO date entry.
  """
  use PinchflatWeb, :html

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :timezone, :string, required: true
  attr :required, :boolean, default: true
  attr :presets, :list, default: []
  attr :presets_inline, :boolean, default: false
  attr :rest, :global, doc: "extra attributes for the picker root, such as x-modelable to share its value"

  @doc """
  Renders a date field and calendar. Submits a YYYY-MM-DD string.
  """
  def date_picker(assigns) do
    today = assigns.timezone |> DateTime.now!() |> DateTime.to_date() |> Date.to_iso8601()
    assigns = assign(assigns, :today, today)

    ~H"""
    <div
      id={"#{@id}-picker"}
      phx-update="ignore"
      class="min-w-0"
      x-data={"pinchflatDatePicker(#{Jason.encode!(@value)}, #{Jason.encode!(@today)})"}
      title={"Dates use your configured timezone (#{@timezone}). Selected dates are included."}
      x-on:click.outside="open = false"
      x-on:keydown.escape="if (open) { $event.preventDefault(); $event.stopPropagation(); close() }"
      x-on:focusout="if (!$el.contains($event.relatedTarget)) open = false"
      x-on:resize.window="if (open) position()"
      x-on:scroll.window.capture="if (open) position()"
      {@rest}
    >
      <label for={@id} class="mb-1 block text-sm font-medium text-theme-on-surface-muted">{@label}</label>
      <div class={if @presets_inline, do: "flex flex-wrap items-end gap-2", else: nil}>
        <div class={[
          "theme-field-shell theme-input flex min-h-11 items-center gap-2 rounded-m3-sm px-3",
          @presets_inline && "min-w-0 flex-1"
        ]}>
          <input
            id={@id}
            name={@name}
            x-ref="dateInput"
            type="text"
            value={@value}
            x-model="value"
            x-on:change="syncMonth()"
            x-on:click="show()"
            required={@required}
            pattern="[0-9]{4}-[0-9]{2}-[0-9]{2}"
            placeholder="YYYY-MM-DD"
            aria-label={@label}
            class="min-h-11 min-w-0 w-full bg-transparent py-2 text-sm text-theme-on-surface outline-none focus-visible:ring-0 focus-visible:ring-offset-0"
          />
          <button
            :if={!@required}
            type="button"
            x-cloak
            x-show="value !== ''"
            x-on:click="value = ''; syncMonth(); $refs.dateInput.focus()"
            class="theme-field-action"
            aria-label={"Clear #{@label}"}
            title="Remove cutoff"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>

          <button
            x-ref="trigger"
            type="button"
            x-on:click="toggle()"
            class="theme-field-action"
            aria-label={"Choose #{@label}"}
            aria-haspopup="dialog"
            x-bind:aria-expanded="open"
            aria-controls={"#{@id}-calendar"}
          >
            <.icon name="hero-calendar-days" class="h-5 w-5" />
          </button>
        </div>

        <select
          :if={@presets != []}
          class={[
            "theme-input theme-select min-h-11 rounded-m3-sm px-3 py-2 text-sm",
            if(@presets_inline, do: "w-full sm:w-44", else: "mt-2 w-full")
          ]}
          aria-label="Cutoff date presets"
          x-on:change="value = $event.target.value; syncMonth(); $event.target.value = ''"
        >
          <option value="">Presets...</option>

          <option :for={{label, date} <- @presets} value={date}>{label}</option>

          <option value="">Remove cutoff</option>
        </select>
      </div>

      <div
        id={"#{@id}-calendar"}
        x-ref="panel"
        x-cloak
        x-show="open"
        class="theme-calendar-panel fixed z-[100] overflow-y-auto"
        x-bind:style="panelStyle"
        role="dialog"
        aria-label={"Choose #{@label}"}
      >
        <div class="mb-3 flex items-center justify-between gap-2">
          <button
            type="button"
            class="theme-icon-button-compact flex items-center justify-center"
            aria-label="Previous month"
            x-on:click="changeMonth(-1)"
          >
            <.icon name="hero-chevron-left" class="h-4 w-4" />
          </button>
          <span class="text-sm font-medium" x-text="monthLabel()" aria-live="polite"></span>
          <button
            type="button"
            class="theme-icon-button-compact flex items-center justify-center"
            aria-label="Next month"
            x-on:click="changeMonth(1)"
          >
            <.icon name="hero-chevron-right" class="h-4 w-4" />
          </button>
        </div>

        <div class="mb-1 grid grid-cols-7 text-center text-xs text-theme-on-surface-muted" aria-hidden="true">
          <span :for={day <- ~w(Su Mo Tu We Th Fr Sa)} class="py-1">{day}</span>
        </div>

        <div x-ref="days" class="theme-calendar-grid" x-on:keydown="navigate($event)" role="group" aria-label="Days">
          <template x-for="day in days()" x-bind:key="day.iso">
            <button
              type="button"
              class="theme-calendar-day"
              x-text="day.number"
              x-bind:data-date="day.iso"
              x-bind:aria-label="day.label"
              x-bind:aria-pressed="day.iso === value"
              x-bind:tabindex="day.iso === focused ? 0 : -1"
              x-bind:class="day.iso === value ? 'bg-theme-primary text-theme-on-primary' : day.currentMonth ? 'text-theme-on-surface' : 'text-theme-on-surface-muted'"
              x-on:click="select(day.iso)"
            ></button>
          </template>
        </div>
      </div>
    </div>
    """
  end
end
