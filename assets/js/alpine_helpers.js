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

window.settingsPage = () => ({
  query: '',
  selectedGroup: '',
  advancedMode: JSON.parse(localStorage.getItem('advancedMode') || 'false'),
  groups: {
    'media-servers': 'media servers plex jellyfin emby refresh scan library integrations',
    access: 'api access sharing share tokens bookmarklet shortcuts credentials',
    notifications:
      'notifications notify apprise server webhook discord telegram email external base url public pinchflat',
    extractor:
      'extractor youtube api key sleep interval throughput download workers indexing metadata concurrency restrict filenames ascii ignore unavailable members-only private time format 12h 24h clock database compaction vacuum sqlite',
    discovery:
      'discovery channel suggestions scheduled scan mention mentions metadata featured subscribed',
    database: 'database postgresql postgres migration migrate transfer sqlite setup connection',
    ytdlp:
      'yt-dlp ytdlp youtube-dl update nightly stable pinned version base config force-ipv4 retries fragment-retries socket-timeout ipv4',
    codec: 'codec video audio avc m4a remux preference mp4',
    cookies:
      'cookies cookie netscape cookies.txt members-only age-restricted default cookie behavior',
    storage: 'storage disk space protection low space free threshold resume paused'
  },
  init() {
    this.applyHash()
    window.addEventListener('hashchange', () => this.applyHash())
    this.$watch('advancedMode', (value) => {
      localStorage.setItem('advancedMode', JSON.stringify(value))
    })
  },
  applyHash() {
    const hash = (window.location.hash || '').replace('#', '')

    if (hash === 'postgres-backups' || hash === 'backups') {
      window.location.replace('/backups')
    }
  },
  selectGroup(id) {
    this.selectedGroup = this.selectedGroup === id ? '' : id

    history.replaceState(null, '', `${window.location.pathname}${window.location.search}`)
  },
  match(text) {
    const query = this.query.trim().toLowerCase()
    if (!query) return true

    const haystack = String(text || '').toLowerCase()
    return query.split(/\s+/).every((word) => haystack.includes(word))
  },
  matchGroup(id) {
    if (this.selectedGroup && this.selectedGroup !== id) return false

    return this.match(this.groups[id])
  }
})

window.dispatchFor = (elementOrId, eventName, detail = {}) => {
  const element =
    typeof elementOrId === 'string' ? document.getElementById(elementOrId) : elementOrId

  // This is needed to ensure the DOM has updated before dispatching the event.
  // Doing so ensures that the latest DOM state is what's sent to the server
  setTimeout(() => {
    element.dispatchEvent(new Event(eventName, { bubbles: true, detail }))
  }, 0)
}
