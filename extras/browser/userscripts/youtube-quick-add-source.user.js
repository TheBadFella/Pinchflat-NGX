// ==UserScript==
// @name         Pinchflat-NGX: YouTube quick add
// @namespace    https://github.com/TheBadFella/Pinchflat-NGX
// @version      1.2.0-pinchflat-ngx
// @description  Add Pinchflat-NGX sources from YouTube with the full New Source form prefilled.
// @author       Adapted by TheBadFella; contributed originally by Asinin3 (https://github.com/Asinin3)
// @homepageURL  https://github.com/TheBadFella/Pinchflat-NGX/wiki/Sharing-and-bookmarklets
// @supportURL   https://github.com/TheBadFella/Pinchflat-NGX/discussions/227
// @license      AGPL-3.0-or-later
// @match        https://www.youtube.com/*
// @match        https://m.youtube.com/*
// @grant        GM_openInTab
// @run-at       document-idle
// ==/UserScript==
//
// Prefer installing from your instance (Settings → API & Access): the hosted copy
// sets PINCHFLAT_BASE from External base URL. Edit below only for a manual install.

;(() => {
  /** External base URL from Pinchflat Settings (no trailing slash). */
  const PINCHFLAT_BASE = 'https://pinchflat.example'

  const newSourceUrl = (info) => {
    if (!info?.url) return null
    const base = PINCHFLAT_BASE.replace(/\/$/, '')
    const target = new URL(`${base}/sources/new`)
    target.searchParams.set('original_url', info.url)
    if (info.name) {
      target.searchParams.set('custom_name', info.name)
      target.searchParams.set('custom_name_locked', 'true')
    }
    if (info.type) target.searchParams.set('source_type', info.type)
    target.searchParams.set('download_members_only_media', 'false')
    return target.toString()
  }

  const mk = (tag, css = '', text = '') => {
    const e = document.createElement(tag)
    e.style.cssText = css
    e.textContent = text
    return e
  }

  const SEP = ' | '
  const NO_LIST = /^(RD|WL|LL)/
  const yt = (p) => `https://www.youtube.com${p}`
  const Q = (s, r = document) => r.querySelector(s)
  const abs = (h) => {
    try {
      return new URL(h, location.origin)
    } catch {
      return null
    }
  }
  const txt = (n) => ((n && (n.getAttribute('title') || n.textContent)) || '').trim()
  const first = (sels, root) => {
    for (const s of sels) {
      const t = txt(Q(s, root))
      if (t) return t
    }
    return ''
  }
  const clean = (s) =>
    s
      .replace(/^\(\d+\)\s*/, '')
      .replace(/\s*-\s*YouTube$/, '')
      .trim()
  const onWatch = () => location.pathname === '/watch'
  const CHAN = /^\/(@[^/]+|channel\/[^/]+|c\/[^/]+|user\/[^/]+)/

  const TITLE = [
    '#video-title',
    '#video-title-link',
    '.yt-lockup-metadata-view-model__title',
    'h3 a',
    'a[href*="/watch?v="]'
  ]
  const OWNER = [
    '#owner-text a',
    '#channel-name a',
    'ytd-channel-name a',
    'ytd-playlist-byline-renderer a',
    'yt-content-metadata-view-model a[href^="/@"]',
    'a[href^="/@"]',
    'a[href*="/channel/"]'
  ]
  const PAGE_OWNER = [
    'ytd-playlist-header-renderer #owner-text a',
    'ytd-playlist-header-renderer ytd-channel-name a',
    'ytd-playlist-panel-renderer #owner-text a',
    'ytd-playlist-panel-renderer #publisher-container a',
    'ytd-playlist-panel-renderer #owner-name a',
    'ytd-playlist-panel-renderer ytd-channel-name a',
    'ytd-playlist-byline-renderer a',
    'yt-page-header-view-model yt-content-metadata-view-model a[href^="/@"]',
    'yt-page-header-view-model a[href*="/channel/"]'
  ]
  const PL_TITLE = [
    'ytd-playlist-header-renderer h1',
    'ytd-playlist-panel-renderer #header #title',
    'ytd-playlist-panel-renderer #title',
    'yt-dynamic-text-view-model h1'
  ]
  const CHANNEL_H1 = [
    'yt-page-header-view-model h1',
    'yt-page-header-renderer h1',
    '#channel-header ytd-channel-name #text'
  ]

  const channelName = () => first(CHANNEL_H1) || clean(document.title)
  const playlist = (id, title, owner) => ({
    url: yt(`/playlist?list=${encodeURIComponent(id)}`),
    type: 'playlist',
    name: (owner ? owner + SEP : '') + (title || 'YouTube playlist')
  })
  const videoUrl = (href) => {
    const u = abs(href)
    if (!u) return null
    const id = u.searchParams.get('v')
    if (u.pathname === '/watch' && id) return yt(`/watch?v=${encodeURIComponent(id)}`)
    const m = u.pathname.match(/^\/(shorts|live)\/([^/?]+)/)
    return m ? yt(`/${m[1]}/${m[2]}`) : null
  }

  const cardInfo = (card) => {
    const title = first(TITLE, card)
    for (const a of card.querySelectorAll('a[href*="list="]')) {
      const id = abs(a.getAttribute('href'))?.searchParams.get('list')
      if (id && !NO_LIST.test(id))
        return playlist(
          id,
          title,
          first(OWNER, card) || (CHAN.test(location.pathname) ? channelName() : '')
        )
    }
    for (const a of card.querySelectorAll(
      'a[href*="/watch?v="],a[href*="/shorts/"],a[href*="/live/"]'
    )) {
      const url = videoUrl(a.getAttribute('href'))
      if (url) return { url, type: 'video', name: title }
    }
    return null
  }

  const watchVideo = () => {
    const url = onWatch() && videoUrl(location.href)
    return url
      ? {
          url,
          type: 'video',
          name:
            first(['ytd-watch-metadata h1 yt-formatted-string', 'ytd-watch-metadata h1']) ||
            clean(document.title)
        }
      : null
  }
  const watchChannel = () => {
    if (!onWatch()) return null
    const a = Q(
      'ytd-watch-metadata #owner a[href^="/@"], ytd-watch-metadata #owner a[href*="/channel/"]'
    )
    if (!a) return null
    const href = a.getAttribute('href').replace(/\/$/, '')
    const path = abs(href)?.pathname || href
    return {
      url: path.startsWith('http') ? path : yt(path),
      type: 'channel',
      name: txt(Q('ytd-watch-metadata #owner ytd-channel-name a')) || txt(a)
    }
  }
  const curPlaylist = () => {
    const id = new URLSearchParams(location.search).get('list')
    return id && !NO_LIST.test(id) ? playlist(id, first(PL_TITLE), first(PAGE_OWNER)) : null
  }
  const curChannel = () => {
    const m = location.pathname.match(CHAN)
    return m ? { url: yt(m[0]), type: 'channel', name: channelName() } : null
  }

  const send = async (info) => {
    if (!info?.url) return
    if (info.type === 'playlist') {
      try {
        const r = await fetch('/oembed?format=json&url=' + encodeURIComponent(info.url))
        const j = r.ok ? await r.json() : null
        if (j?.title) info = { ...info, name: (j.author_name ? j.author_name + SEP : '') + j.title }
      } catch {
        /* use page-derived name */
      }
    }
    const openUrl = newSourceUrl(info)
    if (openUrl) GM_openInTab(openUrl, { active: true })
  }

  const BTN = 30
  const makeBtn = (label) => {
    const b = mk(
      'button',
      `width:${BTN}px;height:${BTN}px;min-width:${BTN}px;padding:0;display:inline-flex;align-items:center;justify-content:center;background:#e62117;color:#fff;border:none;border-radius:8px;cursor:pointer;z-index:2147483647;box-sizing:border-box;box-shadow:0 2px 6px rgba(0,0,0,.35);transition:background .12s,transform .12s`
    )
    b.type = 'button'
    b.title = label
    b.setAttribute('aria-label', label)
    const NS = 'http://www.w3.org/2000/svg'
    const svg = document.createElementNS(NS, 'svg')
    for (const [k, v] of [
      ['viewBox', '0 0 24 24'],
      ['width', '18'],
      ['height', '18'],
      ['fill', 'currentColor']
    ])
      svg.setAttribute(k, v)
    svg.style.pointerEvents = 'none'
    const path = document.createElementNS(NS, 'path')
    path.setAttribute('d', 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z')
    svg.append(path)
    b.append(svg)
    b.onmouseenter = () => {
      b.style.background = '#c91910'
      b.style.transform = 'scale(1.06)'
    }
    b.onmouseleave = () => {
      b.style.background = '#e62117'
      b.style.transform = 'scale(1)'
    }
    ;['mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach((t) =>
      b.addEventListener(t, (e) => e.stopPropagation())
    )
    return b
  }

  const CARD =
    'ytd-rich-item-renderer,ytd-grid-video-renderer,ytd-video-renderer,ytd-compact-video-renderer,yt-lockup-view-model,ytm-shorts-lockup-view-model'
  const THUMB =
    'ytd-thumbnail,yt-thumbnail-view-model,a#thumbnail,.yt-lockup-view-model__content-image'
  const fb = makeBtn('Add to Pinchflat')
  Object.assign(fb.style, { position: 'fixed', display: 'none' })
  document.body.append(fb)

  let cur = null
  let lastPointer = 0
  const inside = (r, x, y) => !!r && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
  const hide = () => {
    cur = null
    fb.style.display = 'none'
  }

  document.addEventListener(
    'pointermove',
    (e) => {
      const now = performance.now()
      if (now - lastPointer < 48) return
      lastPointer = now
      if (fb.contains(e.target) || inside(cur?.rect, e.clientX, e.clientY)) return
      const card = e.target.closest?.(CARD)
      const thumb = card && Q(THUMB, card)
      const rect = thumb?.getBoundingClientRect()
      const info = rect && inside(rect, e.clientX, e.clientY) ? cardInfo(card) : null
      if (!info) return hide()
      cur = { info, rect }
      fb.title =
        info.type === 'playlist'
          ? 'Add this entire playlist to Pinchflat'
          : 'Add this video to Pinchflat'
      Object.assign(fb.style, {
        left: rect.left + 9 + 'px',
        top: rect.bottom - BTN - 9 + 'px',
        display: 'inline-flex'
      })
    },
    true
  )
  fb.onclick = (e) => {
    e.preventDefault()
    e.stopPropagation()
    send(cur?.info)
  }
  addEventListener('scroll', hide, { passive: true, capture: true })
  addEventListener('resize', hide, { passive: true })
  document.documentElement.addEventListener('mouseleave', hide)

  const slots = [
    {
      key: 'video',
      label: 'Add this video to Pinchflat',
      get: watchVideo,
      host: () => Q('ytd-watch-metadata h1, #title h1')?.parentElement
    },
    {
      key: 'wchan',
      label: 'Add this channel to Pinchflat',
      get: watchChannel,
      host: () => Q('ytd-watch-metadata #owner')
    },
    {
      key: 'plside',
      label: 'Add this entire playlist to Pinchflat',
      get: curPlaylist,
      host: () => {
        const p = Q('ytd-playlist-panel-renderer')
        return (
          p &&
          (Q('#header #title', p)?.parentElement || Q('#header', p) || Q('#header-container', p))
        )
      }
    },
    {
      key: 'plpage',
      label: 'Add this entire playlist to Pinchflat',
      get: () => (location.pathname === '/playlist' ? curPlaylist() : null),
      host: () =>
        Q('ytd-playlist-header-renderer h1, #header h1, yt-dynamic-text-view-model h1')
          ?.parentElement
    },
    {
      key: 'chan',
      label: 'Add this entire channel to Pinchflat',
      get: curChannel,
      host: () =>
        Q('yt-page-header-view-model h1, yt-page-header-renderer h1, #channel-header h1')
          ?.parentElement
    }
  ]

  const tick = () =>
    slots.forEach((s) => {
      const info = s.get()
      const host = info && s.host()
      if (host && !Q(`:scope > [data-pf-key="${s.key}"]`, host)) {
        if (!host.dataset.pfStyled) {
          host.dataset.pfStyled = 1
          Object.assign(host.style, {
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            minWidth: '0'
          })
        }
        const b = makeBtn(s.label)
        b.dataset.pfKey = s.key
        Object.assign(b.style, {
          position: 'relative',
          flex: '0 0 auto',
          marginInlineStart: '10px'
        })
        b.onclick = (e) => {
          e.preventDefault()
          e.stopPropagation()
          send(s.get())
        }
        host.append(b)
      }
      document
        .querySelectorAll(`[data-pf-key="${s.key}"]`)
        .forEach((b) => (b.style.display = info ? 'inline-flex' : 'none'))
    })

  setInterval(tick, 1000)
  document.addEventListener('yt-navigate-finish', () => {
    hide()
    tick()
  })
})()
