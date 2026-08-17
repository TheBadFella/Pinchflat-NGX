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
  return localStorage.getItem('sidebarCollapsed') === 'true'
}

window.setSidebarCollapsed = (collapsed) => {
  localStorage.setItem('sidebarCollapsed', collapsed ? 'true' : 'false')
}

window.settingsPage = () => ({
  query: '',
  advancedMode: JSON.parse(localStorage.getItem('advancedMode') || 'false'),
  groups: {
    notifications:
      'notifications notify apprise server webhook discord telegram email external base url public pinchflat',
    extractor:
      'extractor youtube api key sleep interval throughput download workers indexing metadata concurrency restrict filenames ascii ignore unavailable members-only private time format 12h 24h clock database compaction vacuum sqlite',
    ytdlp:
      'yt-dlp ytdlp youtube-dl update nightly stable pinned version base config force-ipv4 retries fragment-retries socket-timeout ipv4',
    codec: 'codec video audio avc m4a remux preference mp4',
    cookies:
      'cookies cookie netscape cookies.txt members-only age-restricted default cookie behavior'
  },
  init() {
    this.$watch('advancedMode', (value) => {
      localStorage.setItem('advancedMode', JSON.stringify(value))
    })
  },
  match(text) {
    const query = this.query.trim().toLowerCase()
    if (!query) return true

    const haystack = String(text || '').toLowerCase()
    return query.split(/\s+/).every((word) => haystack.includes(word))
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
