// Client side of PinchflatWeb.CommandPaletteLive: visibility, shortcuts,
// keyboard movement and focus. The server only answers queries.

const TYPING_TAGS = new Set(['INPUT', 'TEXTAREA', 'SELECT'])

function isTyping(el) {
  return !!el && (TYPING_TAGS.has(el.tagName) || el.isContentEditable)
}

function isApple() {
  const platform = navigator.userAgentData?.platform || navigator.platform || ''
  return /mac|iphone|ipad|ipod/i.test(platform)
}

export const commandPalette = {
  mounted() {
    this.dialog = this.el.querySelector('[data-palette-dialog]')
    this.scrim = this.el.querySelector('[data-palette-scrim]')
    this.activeIndex = 0
    this.opener = null

    if (isApple()) {
      document
        .querySelectorAll('[data-command-palette-shortcut]')
        .forEach((el) => (el.textContent = '⌘ K'))
    }

    this.onDocumentKeydown = (event) => {
      const shortcut = (event.key === 'k' || event.key === 'K') && (event.ctrlKey || event.metaKey)

      if (shortcut) {
        event.preventDefault()
        this.isOpen() ? this.close() : this.open(null)
      } else if (event.key === '/' && !this.isOpen() && !isTyping(document.activeElement)) {
        event.preventDefault()
        this.open(null)
      }
    }

    this.onDocumentClick = (event) => {
      const trigger = event.target.closest('[data-open-command-palette]')

      if (trigger) {
        event.preventDefault()
        this.open(trigger)
      }
    }

    this.onPaletteKeydown = (event) => this.handlePaletteKey(event)

    this.onPaletteClick = (event) => {
      if (event.target.closest('[data-palette-cancel]')) {
        this.close()
      } else if (event.target.closest('[data-palette-clear]')) {
        this.setQuery('')
        this.input().focus()
      } else if (event.target.closest('[data-palette-scope]')) {
        this.activeIndex = 0
        this.input().focus()
      }
    }

    this.onPaletteMousemove = (event) => {
      const option = event.target.closest('[role="option"]')
      const index = this.options().indexOf(option)

      if (index >= 0 && index !== this.activeIndex) {
        this.activeIndex = index
        this.paint(false)
      }
    }

    this.onScrimClick = () => this.close()

    document.addEventListener('keydown', this.onDocumentKeydown)
    document.addEventListener('click', this.onDocumentClick)
    this.input().addEventListener('input', () => {
      clearTimeout(this.searchTimer)
      const query = this.input().value
      if (!query.trim()) {
        this.pushEvent('search', { query })
      } else {
        this.searchTimer = setTimeout(() => this.pushEvent('search', { query }), 200)
      }
    })
    this.input().form.addEventListener('submit', (event) => event.preventDefault())

    this.el.addEventListener('keydown', this.onPaletteKeydown)
    this.el.addEventListener('click', this.onPaletteClick)
    this.el.addEventListener('mousemove', this.onPaletteMousemove)
    this.scrim.addEventListener('click', this.onScrimClick)
  },

  updated() {
    this.activeIndex = 0
    this.paint(true)
  },

  destroyed() {
    clearTimeout(this.searchTimer)
    document.removeEventListener('keydown', this.onDocumentKeydown)
    document.removeEventListener('click', this.onDocumentClick)
  },

  input() {
    return this.el.querySelector('[data-palette-input]')
  },

  options() {
    return Array.from(this.el.querySelectorAll('[role="option"]'))
  },

  isOpen() {
    return this.dialog.style.display !== 'none'
  },

  open(opener) {
    if (this.isOpen()) return

    this.opener = opener
    this.closeSidebarDrawer()
    // liveSocket.js() keeps show/hide across server patches.
    this.js().show(this.scrim)
    this.js().show(this.dialog, { display: 'flex' })
    this.dialog.setAttribute('data-opening', '')
    setTimeout(() => this.dialog.removeAttribute('data-opening'), 200)

    // js().show applies on the next frame; show it now too so focus lands immediately.
    this.scrim.style.display = 'block'
    this.dialog.style.display = 'flex'

    this.activeIndex = 0
    this.paint(true)
    const input = this.input()
    input.focus()
    input.select()
    requestAnimationFrame(() => {
      if (this.isOpen() && document.activeElement !== input) input.focus()
    })
  },

  close() {
    if (!this.isOpen()) return

    this.js().hide(this.dialog)
    this.js().hide(this.scrim)
    this.dialog.style.display = 'none'
    this.scrim.style.display = 'none'
    clearTimeout(this.searchTimer)
    this.input().value = ''
    this.pushEvent('reset', {})

    const opener =
      this.opener && document.contains(this.opener) ? this.opener : this.fallbackOpener()
    this.input().blur()
    opener?.focus()
    this.opener = null
  },

  fallbackOpener() {
    const id = window.matchMedia('(min-width: 64rem)').matches
      ? 'sidebar-search-button'
      : 'phone-bar-search-button'
    return document.getElementById(id)
  },

  closeSidebarDrawer() {
    const data = window.Alpine?.$data?.(document.body)
    if (data && data.sidebarVisible) data.sidebarVisible = false
  },

  setQuery(value) {
    clearTimeout(this.searchTimer)
    const input = this.input()
    input.value = value
    this.pushEvent('search', { query: value })
  },

  handlePaletteKey(event) {
    const options = this.options()

    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      if (options.length === 0) return
      const step = event.key === 'ArrowDown' ? 1 : -1
      this.activeIndex = (this.activeIndex + step + options.length) % options.length
      this.paint(true)
    } else if (event.key === 'Enter' && event.target === this.input()) {
      event.preventDefault()
      options[this.activeIndex]?.click()
    } else if (event.key === 'Escape') {
      event.preventDefault()
      if (this.input().value) {
        this.setQuery('')
      } else {
        this.close()
      }
    } else if (event.key === 'Tab') {
      this.trapFocus(event)
    }
  },

  trapFocus(event) {
    const focusable = Array.from(
      this.dialog.querySelectorAll('input, button, a[href]:not([role="option"])')
    ).filter((el) => el.offsetParent !== null)
    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  },

  paint(scroll) {
    const options = this.options()
    const input = this.input()

    if (this.activeIndex >= options.length) this.activeIndex = 0

    options.forEach((option, index) => {
      option.id = option.id || `command-palette-option-${index}`
      option.setAttribute('aria-selected', index === this.activeIndex ? 'true' : 'false')
    })

    const active = options[this.activeIndex]

    if (active) {
      input.setAttribute('aria-activedescendant', active.id)
      if (scroll) active.scrollIntoView({ block: 'nearest' })
    } else {
      input.removeAttribute('aria-activedescendant')
    }
  }
}
