const dateAt = (year, month, day) => {
  const date = new Date(0)
  date.setFullYear(year, month, day)
  date.setHours(12, 0, 0, 0)
  return date
}

const isoDate = (date) =>
  `${String(date.getFullYear()).padStart(4, '0')}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`

const parseDate = (value) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null
  const [year, month, day] = value.split('-').map(Number)
  const date = dateAt(year, month - 1, day)
  return isoDate(date) === value ? date : null
}

export const datePicker = (initialValue, today) => ({
  value: initialValue,
  open: false,
  year: 0,
  month: 0,
  focused: '',
  panelStyle: {},
  init() {
    this.syncMonth()
  },
  syncMonth() {
    const date = parseDate(this.value) || parseDate(today) || new Date()
    this.year = date.getFullYear()
    this.month = date.getMonth()
    this.focused = isoDate(date)
  },
  monthLabel() {
    return dateAt(this.year, this.month, 1).toLocaleDateString(undefined, {
      month: 'long',
      year: 'numeric'
    })
  },
  days() {
    const offset = dateAt(this.year, this.month, 1).getDay()
    return Array.from({ length: 42 }, (_, index) => {
      const date = dateAt(this.year, this.month, index - offset + 1)
      return {
        iso: isoDate(date),
        number: date.getDate(),
        currentMonth: date.getMonth() === this.month,
        label: date.toLocaleDateString(undefined, { dateStyle: 'full' })
      }
    })
  },
  position() {
    const anchor = this.$refs.trigger.parentElement.getBoundingClientRect()
    const header = document.querySelector('header')?.getBoundingClientRect().bottom || 0
    const top = Math.max(8, header + 8)
    const touchLayout =
      window.innerWidth < 640 || window.matchMedia('(any-pointer: coarse)').matches
    const margin = touchLayout ? 1 : 16
    const width = touchLayout
      ? Math.min(360, window.innerWidth - 2)
      : Math.min(304, window.innerWidth - 32)
    this.$refs.panel.style.width = `${width}px`
    const height = Math.min(this.$refs.panel.scrollHeight, window.innerHeight - top - 16)
    this.panelStyle = {
      width: `${width}px`,
      left: `${Math.max(margin, Math.min(anchor.left, window.innerWidth - width - margin))}px`,
      top: `${Math.max(top, Math.min(anchor.bottom + 8, window.innerHeight - height - 16))}px`,
      maxHeight: `${window.innerHeight - top - 16}px`
    }
  },
  focusDay() {
    this.$nextTick(() => {
      requestAnimationFrame(() =>
        this.$refs.days
          .querySelector(`[data-date="${this.focused}"]`)
          ?.focus({ preventScroll: true })
      )
    })
  },
  toggle() {
    if (this.open) return this.close()
    this.syncMonth()
    this.open = true
    this.$nextTick(() => {
      requestAnimationFrame(() => {
        this.position()
        this.focusDay()
      })
    })
  },
  close() {
    this.open = false
    this.$refs.trigger.focus()
  },
  select(value) {
    this.value = value
    this.close()
  },
  changeMonth(offset) {
    const date = dateAt(this.year, this.month + offset, 1)
    if (date.getFullYear() < 1 || date.getFullYear() > 9999) return
    this.year = date.getFullYear()
    this.month = date.getMonth()
    this.focused = isoDate(date)
  },
  navigate(event) {
    const date = parseDate(this.focused)
    const offsets = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }
    if (event.key in offsets) date.setDate(date.getDate() + offsets[event.key])
    else if (event.key === 'Home') date.setDate(date.getDate() - date.getDay())
    else if (event.key === 'End') date.setDate(date.getDate() + 6 - date.getDay())
    else if (event.key === 'PageUp' || event.key === 'PageDown') {
      this.changeMonth(event.key === 'PageUp' ? -1 : 1)
      event.preventDefault()
      this.focusDay()
      return
    } else return
    event.preventDefault()
    this.year = date.getFullYear()
    this.month = date.getMonth()
    this.focused = isoDate(date)
    this.focusDay()
  }
})
