export const browseSearch = {
  restore() {
    const params = new URL(window.location.href).searchParams
    this.pushEvent('restore_search', {
      q: params.get('q') || '',
      tab: params.get('tab') || 'videos',
      profile: params.get('profile') || ''
    })
  },
  mounted() {
    this.handleEvent('browse:remember', (params) => {
      const url = new URL(window.location.href)
      for (const key of ['url', 'prefill', 'quick_url']) url.searchParams.delete(key)
      for (const key of ['q', 'tab', 'profile']) {
        if (params[key] == null || params[key] === '') url.searchParams.delete(key)
        else url.searchParams.set(key, params[key])
      }
      window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`)
    })
    this.restore()
  },
  reconnected() {
    this.restore()
  }
}
