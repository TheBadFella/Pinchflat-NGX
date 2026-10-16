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
      title={"Dates use your configured timezone (#{@timezone}). Both selected dates are included."}
      x-on:click.outside="open = false"
      x-on:keydown.escape="if (open) { $event.preventDefault(); $event.stopPropagation(); close() }"
      x-on:focusout="if (!$el.contains($event.relatedTarget)) open = false"
      x-on:resize.window="if (open) position()"
      x-on:scroll.window.capture="if (open) position()"
    >
      <label for={@id} class="mb-1 block text-sm font-medium text-theme-on-surface-muted">{@label}</label>
      <div class="theme-field-shell theme-input flex min-h-11 items-center gap-2 rounded-m3-sm px-3">
        <input
          id={@id}
          name={@name}
          type="text"
          value={@value}
          x-model="value"
          x-on:change="syncMonth()"
          required
          pattern="[0-9]{4}-[0-9]{2}-[0-9]{2}"
          placeholder="YYYY-MM-DD"
          aria-label={@label}
          class="min-w-0 w-full bg-transparent py-2 text-sm text-theme-on-surface outline-none"
        />
        <button
          x-ref="trigger"
          type="button"
          x-on:click="toggle()"
          class="theme-icon-button-compact flex shrink-0 items-center justify-center"
          aria-label={"Choose #{@label}"}
          aria-haspopup="dialog"
          x-bind:aria-expanded="open"
          aria-controls={"#{@id}-calendar"}
        >
          <.icon name="hero-calendar-days" class="h-4 w-4" />
        </button>
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

        <p class="mt-3 text-xs text-theme-on-surface-muted">YYYY-MM-DD</p>
      </div>
    </div>
    """
  end
end
