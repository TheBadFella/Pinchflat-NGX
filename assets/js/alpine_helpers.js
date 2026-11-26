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
// group is `details[data-setting-group]`.
window.settingsNav = () => {
  let root
  let sectionLockTimer

  return {
    settingQuery: '',
    settingMatches: 0,
    activeSection: '',
    sectionLocked: false,
    // Highlight a section and hold it briefly: the scroll a jump causes would otherwise let the
    // observer pick the section it passes through.
    showSection(id) {
      this.activeSection = id || this.activeSection
      this.sectionLocked = true
      clearTimeout(sectionLockTimer)
      sectionLockTimer = setTimeout(() => (this.sectionLocked = false), 400)
    },
    init() {
      root = this.$el
      root
        .querySelectorAll('[data-settings] label[for]:not(.theme-switch-target)')
        .forEach((label) => {
          if (label.closest('[data-setting]')) return
          // a field whose label sits deeper than its input (toggle row) marks its own wrapper
          ;(label.closest('[data-setting-field]') || label.parentElement).dataset.setting = ''
        })
      this.$watch('settingQuery', () => this.filterSettings())

      const sections = [...root.querySelectorAll('section[data-setting-group][id]')]
      this.activeSection = sections[0]?.id || ''

      window.addEventListener('hashchange', () => this.goToSetting(location.hash.slice(1)))
      if (location.hash.length > 1) this.$nextTick(() => this.goToSetting(location.hash.slice(1)))

      const inView = new Set()
      const sectionObserver = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) =>
            entry.isIntersecting ? inView.add(entry.target.id) : inView.delete(entry.target.id)
          )
          if (this.sectionLocked) return
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
      if (!element || !root.contains(element) || element.closest('[data-setting-inapplicable]'))
        return
      if (element.matches('section[data-setting-group]')) return this.showSection(target)
      const setting = element.closest('[data-setting]')
      if (!setting || setting.closest('[data-setting-inapplicable]')) return

      this.settingQuery = ''
      for (
        let group = setting.closest('details');
        group;
        group = group.parentElement.closest('details')
      ) {
        group.open = true
      }
      // wait briefly so a just-opened group has a layout to scroll to
      setTimeout(() => {
        setting.scrollIntoView({ block: 'center' })
        setting
          .querySelector('input:not([type=hidden]), textarea, select, button')
          ?.focus({ preventScroll: true })
        history.replaceState(null, '', '#' + target)
        this.showSection(setting.closest('section[data-setting-group][id]')?.id)
        // mark where the jump landed, long enough to find it
        setting.classList.add('theme-setting-jump')
        setTimeout(() => setting.classList.remove('theme-setting-jump'), 2000)
      }, 50)
    },
    filterSettings() {
      const words = this.settingQuery.trim().toLowerCase().split(/\s+/).filter(Boolean)
      const settings = [...root.querySelectorAll('[data-setting]')]
      settings.forEach((setting) => {
        if (setting.closest('[data-setting-inapplicable]')) {
          setting.hidden = true
          return
        }
        // the section heading counts too, so a section's name finds all of its settings
        const heading = setting.closest('section[data-setting-group][id]')?.querySelector('h3')
        const text = [setting.textContent, setting.dataset.settingKeywords, heading?.textContent]
          .join(' ')
          .toLowerCase()
        setting.hidden = !words.every((word) => text.includes(word))
      })
      this.settingMatches = settings.filter(
        (setting) => !setting.hidden && !setting.closest('[data-setting-inapplicable]')
      ).length
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
