window.copyTextToClipboard = async (text) => {
  // Navigator clipboard api needs a secure context (https)
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(text)
  } else {
    const textArea = document.createElement('textarea')
    textArea.value = text
    // Move textarea out of the viewport so it's not visible
    textArea.style.position = 'absolute'
    textArea.style.left = '-999999px'

    document.body.prepend(textArea)
    textArea.select()

    try {
      document.execCommand('copy')
    } catch (error) {
      console.error(error)
    } finally {
      textArea.remove()
    }
  }
}

window.copyWithCallbacks = async (text, onCopy, onAfterDelay, delay = 4000) => {
  await window.copyTextToClipboard(text)
  onCopy()
  setTimeout(onAfterDelay, delay)
}

window.getSidebarCollapsed = () => {
  return document.documentElement.dataset.sidebarCollapsed === 'true'
}

window.setSidebarCollapsed = (collapsed) => {
  document.documentElement.dataset.sidebarCollapsed = collapsed ? 'true' : 'false'
  try {
    localStorage.setItem('sidebarCollapsed', collapsed ? 'true' : 'false')
  } catch (_) {
    // Keep navigation usable when browser storage is unavailable.
  }
}

// Section rail, "Find a setting" filter and field deep links for the long settings forms
// (source, media profile, Settings). Markup contract, all inside the x-data root:
// sections are `section[data-setting-group][id]` under `[data-settings]`, one setting is
// `[data-setting]` (the parent of a field label is tagged automatically) and a collapsed
// group is `details[data-setting-group]`. Advanced-only parts use x-show with advancedMode.
window.settingsNav = () => {
  let root
  // After a jump the scroll observer would hand the highlight to whichever section crosses its
  // band (a short or last section never does), so it is held until the reader scrolls on.
  // Scroll events within 300 ms of the jump are the jump's own.
  let heldAt = 0
  const holdActiveSection = () => (heldAt = Date.now())
  const releaseOnScroll = () => {
    if (heldAt && Date.now() - heldAt > 300) heldAt = 0
  }

  return {
    advancedMode: !!JSON.parse(localStorage.getItem('advancedMode') || 'false'),
    settingQuery: '',
    settingMatches: 0,
    activeSection: '',
    sectionSettings: {},
    init() {
      root = this.$el
      this.$watch('advancedMode', (value) => {
        localStorage.setItem('advancedMode', JSON.stringify(value))
      })
      root
        .querySelectorAll('[data-settings] label[for]:not(.theme-switch-target)')
        .forEach((label) => {
          if (!label.closest('[data-setting]')) label.parentElement.dataset.setting = ''
        })
      this.$watch('settingQuery', () => this.filterSettings())

      const sections = [...root.querySelectorAll('section[data-setting-group][id]')]
      this.activeSection = sections[0]?.id || ''
      sections.forEach((section) => {
        this.sectionSettings[section.id] = [...section.querySelectorAll('[data-setting]')].flatMap(
          (setting) => {
            const label = setting.querySelector('label[for]')
            const target = setting.id || label?.htmlFor
            const title =
              setting.dataset.settingLabel || label?.textContent.trim().replace(/\s+/g, ' ')
            const advanced = !!setting.closest('[x-show*=advancedMode]')
            return target && title ? [{ target, title, advanced }] : []
          }
        )
      })

      window.addEventListener('hashchange', () => this.goToSetting(location.hash.slice(1)))
      if (location.hash.length > 1) this.$nextTick(() => this.goToSetting(location.hash.slice(1)))

      window.addEventListener('scroll', releaseOnScroll, { capture: true, passive: true })
      const inView = new Set()
      const sectionObserver = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) =>
            entry.isIntersecting ? inView.add(entry.target.id) : inView.delete(entry.target.id)
          )
          if (heldAt) return
          this.activeSection =
            sections.find((section) => inView.has(section.id))?.id || this.activeSection
        },
        { rootMargin: '-25% 0px -65% 0px' }
      )
      sections.forEach((section) => sectionObserver.observe(section))

      // The phone chip row scrolls sideways: keep the current section's chip in view.
      this.$watch('activeSection', (id) => {
        const link = root.querySelector(`nav a[href="#${id}"]`)
        const nav = link?.closest('nav')
        if (nav) {
          nav.scrollLeft +=
            link.getBoundingClientRect().left - nav.getBoundingClientRect().left - 16
        }
      })
    },
    goToSetting(target) {
      const element = document.getElementById(target)
      if (!element || !root.contains(element)) return
      if (element.matches('section[data-setting-group]')) {
        // a section link: the browser scrolls, only the highlight needs setting
        this.activeSection = target
        return holdActiveSection()
      }
      const setting = element.closest('[data-setting]')
      if (!setting) return

      this.settingQuery = ''
      if (setting.closest('[x-show*=advancedMode]')) this.advancedMode = true
      for (
        let group = setting.closest('details');
        group;
        group = group.parentElement.closest('details')
      ) {
        group.open = true
      }
      // wait briefly so a just-revealed Advanced section has a layout to scroll to
      setTimeout(() => {
        setting.scrollIntoView({ block: 'center' })
        setting
          .querySelector('input:not([type=hidden]), textarea, select, button')
          ?.focus({ preventScroll: true })
        history.replaceState(null, '', '#' + target)
        this.activeSection =
          setting.closest('section[data-setting-group][id]')?.id || this.activeSection
        holdActiveSection()
      }, 50)
    },
    filterSettings() {
      const words = this.settingQuery.trim().toLowerCase().split(/\s+/).filter(Boolean)
      const settings = [...root.querySelectorAll('[data-setting]')]
      settings.forEach((setting) => {
        // the section heading counts too, so a section's name finds all of its settings
        const heading = setting.closest('section[data-setting-group][id]')?.querySelector('h3')
        const text = [setting.textContent, setting.dataset.settingKeywords, heading?.textContent]
          .join(' ')
          .toLowerCase()
        setting.hidden = !words.every((word) => text.includes(word))
      })
      this.settingMatches = settings.filter((setting) => !setting.hidden).length
      root.querySelectorAll('[data-setting-group]').forEach((group) => {
        group.hidden = words.length > 0 && !group.querySelector('[data-setting]:not([hidden])')
        if (words.length > 0 && !group.hidden && group.tagName === 'DETAILS') group.open = true
      })
    }
  }
}

window.settingsPage = () => {
  const nav = window.settingsNav()

  return {
    ...nav,
    init() {
      this.applyHash()
      window.addEventListener('hashchange', () => this.applyHash())
      nav.init.call(this)
    },
    applyHash() {
      const hash = (window.location.hash || '').replace('#', '')

      if (hash === 'postgres-backups' || hash === 'backups') {
        window.location.replace(window.location.pathname.replace(/\/settings\/?$/, '/backups'))
      }
    }
  }
}

window.dispatchFor = (elementOrId, eventName, detail = {}) => {
  const element =
    typeof elementOrId === 'string' ? document.getElementById(elementOrId) : elementOrId

  // This is needed to ensure the DOM has updated before dispatching the event.
  // Doing so ensures that the latest DOM state is what's sent to the server
  setTimeout(() => {
    element.dispatchEvent(new Event(eventName, { bubbles: true, detail }))
  }, 0)
}
