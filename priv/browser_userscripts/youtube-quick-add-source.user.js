// ==UserScript==
// @name         Pinchflat-NGX: YouTube quick add
// @namespace    https://github.com/TheBadFella/Pinchflat-NGX
// @version      1.3.0-pinchflat-ngx
// @description  Add Pinchflat-NGX sources from YouTube with the full New Source form prefilled.
// @author       Adapted by TheBadFella; contributed originally by Asinin3 (https://github.com/Asinin3)
// @downloadURL  __PINCHFLAT_BASE__/browser/userscripts/youtube-quick-add-source.user.js
// @updateURL    __PINCHFLAT_BASE__/browser/userscripts/youtube-quick-add-source.user.js
// @homepageURL  __PINCHFLAT_BASE__/settings
// @supportURL   https://github.com/TheBadFella/Pinchflat-NGX/discussions/227
// @license      AGPL-3.0-or-later
// @match        https://www.youtube.com/*
// @match        https://m.youtube.com/*
// @grant        GM_openInTab
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @grant        GM_unregisterMenuCommand
// @run-at       document-idle
// ==/UserScript==
//
// PINCHFLAT_BASE is set by your Pinchflat-ngx instance when you install from its hosted URL.

;(() => {
  /** External base URL from Pinchflat Settings (no trailing slash). */
  const PINCHFLAT_BASE = __PINCHFLAT_BASE_JS__

  const LOGO_DATA_URI =
    'data:image/png;base64,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'

  const DEFAULTS = {
    skipUpcoming: true,
    channelPagesOnly: false,
    hideShorts: false
  }

  const SETTINGS = [
    ['skipUpcoming', 'Skip upcoming streams & premieres'],
    ['channelPagesOnly', 'Only show thumbnail buttons on channel pages'],
    ['hideShorts', 'Hide buttons on Shorts']
  ]

  const cfg = {}
  for (const k of Object.keys(DEFAULTS)) cfg[k] = GM_getValue(k, DEFAULTS[k])

  const newSourceUrl = (info) => {
    if (!info?.url) return null
    const base = PINCHFLAT_BASE.replace(/\/$/, '')
    const target = new URL(`${base}/sources/new`)
    target.searchParams.set('original_url', info.url)
    if (info.name) target.searchParams.set('custom_name', info.name)
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

  const UPCOMING_RE = /\b(upcoming|scheduled|premieres?|premiering)\b/i
  const REMINDER_RE = /remind|notify me/i
  const BADGES = [
    'ytd-thumbnail-overlay-time-status-renderer',
    'yt-thumbnail-overlay-badge-view-model',
    'yt-thumbnail-badge-view-model',
    'badge-shape'
  ].join(',')
  const META_ROWS = '#metadata-line, .yt-content-metadata-view-model__metadata-row'
  const CHANNEL_LINK = 'a[href^="/@"], a[href*="/channel/"]'

  const isUpcoming = (card) => {
    if (Q('[overlay-style="UPCOMING"]', card)) return true
    for (const el of card.querySelectorAll('button, [aria-label]')) {
      if (REMINDER_RE.test(el.getAttribute('aria-label') || '')) return true
    }
    for (const n of card.querySelectorAll(BADGES)) {
      if (UPCOMING_RE.test(n.textContent)) return true
    }
    for (const n of card.querySelectorAll(META_ROWS)) {
      if (!Q(CHANNEL_LINK, n) && UPCOMING_RE.test(n.textContent)) return true
    }
    return false
  }

  const watchUpcoming = () =>
    ['ytd-watch-info-text', '#info-strings', '.ytp-offline-slate'].some((s) => {
      const el = Q(s)
      return !!el && UPCOMING_RE.test(el.textContent)
    })

  const cardInfo = (card) => {
    if (cfg.skipUpcoming && isUpcoming(card)) return null
    const title = first(TITLE, card)
    const onChannel = CHAN.test(location.pathname)
    for (const a of card.querySelectorAll('a[href*="list="]')) {
      const id = abs(a.getAttribute('href'))?.searchParams.get('list')
      if (id && !NO_LIST.test(id))
        return playlist(id, title, first(OWNER, card) || (onChannel ? channelName() : ''))
    }
    for (const a of card.querySelectorAll(
      'a[href*="/watch?v="],a[href*="/shorts/"],a[href*="/live/"]'
    )) {
      const url = videoUrl(a.getAttribute('href'))
      if (url)
        return cfg.hideShorts && url.includes('/shorts/')
          ? null
          : { url, type: 'video', name: title }
    }
    return null
  }

  const watchVideo = () => {
    if (cfg.skipUpcoming && watchUpcoming()) return null
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
    return m
      ? {
          url: yt(m[0]),
          type: 'channel',
          name: channelName()
        }
      : null
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
  const BG = LOGO_DATA_URI ? '#212121' : '#e62117'
  const BG_HOVER = LOGO_DATA_URI ? '#3a3a3a' : '#c91910'
  const NS = 'http://www.w3.org/2000/svg'

  const iconSvg = (d, size) => {
    const svg = document.createElementNS(NS, 'svg')
    for (const [k, v] of [
      ['viewBox', '0 0 24 24'],
      ['width', String(size)],
      ['height', String(size)],
      ['fill', 'currentColor']
    ])
      svg.setAttribute(k, v)
    svg.style.pointerEvents = 'none'
    svg.style.flex = '0 0 auto'
    const path = document.createElementNS(NS, 'path')
    path.setAttribute('d', d)
    svg.append(path)
    return svg
  }

  const PLUS = 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z'
  const PERSON =
    'M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z'
  const PLAY = 'M8 5v14l11-7z'
  const SPRING = 'cubic-bezier(.34,1.56,.64,1)'

  const plusSvg = (size) => {
    const svg = iconSvg(PLUS, size)
    svg.style.transition = `transform .3s ${SPRING}`
    return svg
  }

  const logoIcon = () => {
    const wrap = mk(
      'span',
      'position:relative;display:block;width:20px;height:20px;pointer-events:none'
    )
    const img = document.createElement('img')
    img.src = LOGO_DATA_URI
    img.alt = ''
    img.draggable = false
    img.style.cssText = 'display:block;width:100%;height:100%;object-fit:contain'
    const badge = mk(
      'span',
      `position:absolute;right:-6px;bottom:-6px;width:12px;height:12px;border-radius:50%;background:#e62117;color:#fff;display:flex;align-items:center;justify-content:center;box-shadow:0 0 0 1.5px ${BG}`
    )
    badge.dataset.pfBadge = '1'
    badge.style.transition = `transform .3s ${SPRING}`
    badge.append(plusSvg(9))
    wrap.append(img, badge)
    return wrap
  }

  const makeBtn = (label) => {
    const b = mk(
      'button',
      `width:${BTN}px;height:${BTN}px;min-width:${BTN}px;padding:0;display:inline-flex;align-items:center;justify-content:center;background:${BG};color:#fff;border:none;border-radius:8px;cursor:pointer;z-index:2147483647;box-sizing:border-box;box-shadow:0 2px 6px rgba(0,0,0,.35);transition:background .12s,transform .12s`
    )
    b.type = 'button'
    b.title = label
    b.setAttribute('aria-label', label)
    b.append(LOGO_DATA_URI ? logoIcon() : plusSvg(18))
    b.onmouseenter = () => {
      b.style.background = BG_HOVER
      b.style.transform = 'scale(1.06)'
    }
    b.onmouseleave = () => {
      b.style.background = BG
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

  const PREVIEW =
    'ytd-video-preview,#video-preview,ytd-player,.html5-video-player,video,[id*="preview" i]'

  const POPOVER = 'popover' in HTMLElement.prototype
  const fb = makeBtn('Add to Pinchflat')
  if (POPOVER) fb.setAttribute('popover', 'manual')
  Object.assign(fb.style, {
    position: 'fixed',
    inset: 'auto',
    margin: '0',
    overflow: 'visible',
    display: 'none'
  })
  document.body.append(fb)

  let cur = null
  let shown = false
  let lastPointer = 0

  const inside = (r, x, y) => !!r && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom

  const hide = () => {
    cur = null
    shown = false
    fb.style.display = 'none'
    if (POPOVER && fb.matches(':popover-open')) fb.hidePopover()
  }

  const show = () => {
    fb.style.display = 'inline-flex'
    if (shown) return
    shown = true
    if (!POPOVER) return
    if (fb.matches(':popover-open')) fb.hidePopover()
    fb.showPopover()
  }

  const thumbsBlocked = () => cfg.channelPagesOnly && !CHAN.test(location.pathname)

  const cardAt = (e) => {
    const t = e.target
    const direct = t.closest?.(CARD)
    if (direct) return direct
    if (!t.closest?.(PREVIEW)) return null
    for (const el of document.elementsFromPoint(e.clientX, e.clientY)) {
      if (el === fb) continue
      const c = el.closest?.(CARD)
      if (c) return c
    }
    return null
  }

  const BAR =
    '.ytp-chrome-bottom,.ytp-progress-bar-container,.ytp-progress-bar,.ytp-scrubber-container,.ytp-timed-markers-container'
  const BAR_PX = 14

  const overBar = (e, rect) => {
    const t = e.target
    if (t.closest?.(BAR)) return true
    return !!t.closest?.(PREVIEW) && e.clientY >= rect.bottom - BAR_PX
  }

  const place = (rect) =>
    Object.assign(fb.style, {
      left: rect.left + 9 + 'px',
      top: rect.bottom - BTN - 9 + 'px'
    })

  const run = (e) => {
    if (thumbsBlocked()) return cur && hide()
    if (fb.contains(e.target)) return

    const card = cardAt(e)
    const thumb = card && Q(THUMB, card)
    const rect = thumb?.getBoundingClientRect()
    if (!rect || !inside(rect, e.clientX, e.clientY)) return hide()

    if (overBar(e, rect)) return hide()

    if (cur?.card === card) {
      cur.rect = rect
      place(rect)
      return
    }

    const info = cardInfo(card)
    if (!info) return hide()

    cur = { info, rect, card, thumb }
    const label =
      info.type === 'playlist'
        ? 'Add this entire playlist to Pinchflat'
        : 'Add this video to Pinchflat'
    fb.title = label
    fb.setAttribute('aria-label', label)
    place(rect)
    show()
  }

  let lastEvt = null
  let timer = 0
  document.addEventListener(
    'pointermove',
    (e) => {
      const wait = 48 - (performance.now() - lastPointer)
      if (wait > 0) {
        lastEvt = e
        if (!timer)
          timer = setTimeout(() => {
            timer = 0
            lastPointer = performance.now()
            run(lastEvt)
          }, wait)
        return
      }
      lastPointer = performance.now()
      run(e)
    },
    true
  )

  fb.onclick = (e) => {
    e.preventDefault()
    e.stopPropagation()
    send(cur?.info)
  }

  const revalidate = () => {
    if (!cur) return
    const r = cur.thumb.isConnected && cur.thumb.getBoundingClientRect()
    if (!r || Math.abs(r.left - cur.rect.left) > 1 || Math.abs(r.top - cur.rect.top) > 1) hide()
  }
  addEventListener('scroll', revalidate, { passive: true, capture: true })
  addEventListener('resize', revalidate, { passive: true })
  document.documentElement.addEventListener('mouseleave', hide)

  const EASE = 'cubic-bezier(.4,0,.2,1)'
  const DUR = 0.34
  const combos = new Set()

  document.addEventListener(
    'click',
    (e) => combos.forEach((c) => !c.root.contains(e.target) && c.collapse()),
    true
  )
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      combos.forEach((c) => c.collapse(c.root.contains(document.activeElement)))
    }
  })

  const makeWatchCombo = () => {
    const root = mk(
      'div',
      `display:inline-flex;align-items:center;box-sizing:border-box;width:${BTN}px;height:${BTN}px;overflow:hidden;background:${BG};color:#fff;border-radius:8px;box-shadow:0 2px 6px rgba(0,0,0,.35);transition:width ${DUR}s ${EASE},border-radius ${DUR}s ${EASE}`
    )
    const toggle = mk(
      'button',
      `width:${BTN}px;height:${BTN}px;min-width:${BTN}px;padding:0;border:none;background:transparent;color:#fff;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;flex:0 0 auto;transition:background .15s`
    )
    toggle.type = 'button'
    const icon = LOGO_DATA_URI ? logoIcon() : plusSvg(18)
    toggle.append(icon)
    const spin = Q('[data-pf-badge]', toggle) || icon
    toggle.onmouseenter = () => (toggle.style.background = 'rgba(255,255,255,.14)')
    toggle.onmouseleave = () => (toggle.style.background = 'transparent')

    const opts = mk(
      'div',
      `display:flex;align-items:center;flex:0 0 auto;visibility:hidden;transition:visibility 0s linear ${DUR}s`
    )

    let open = false
    const setLabel = () => {
      const t = open ? 'Close' : 'Add to Pinchflat…'
      toggle.title = t
      toggle.setAttribute('aria-label', t)
      toggle.setAttribute('aria-expanded', String(open))
    }

    const collapse = (restoreFocus = false) => {
      if (!open) return
      open = false
      root.style.width = BTN + 'px'
      root.style.borderRadius = '8px'
      opts.style.transitionDelay = `${DUR}s`
      opts.style.visibility = 'hidden'
      for (const c of opts.children) {
        c.style.transitionDelay = '0ms'
        c.style.opacity = '0'
        c.style.transform = 'translateX(-10px)'
      }
      spin.style.transform = ''
      setLabel()
      if (restoreFocus) toggle.focus()
    }

    const seg = (label, d, title, getInfo) => {
      const b = mk(
        'button',
        `height:${BTN}px;padding:0 13px 0 11px;border:none;border-left:1px solid rgba(255,255,255,.18);background:transparent;color:#fff;display:inline-flex;align-items:center;gap:6px;cursor:pointer;white-space:nowrap;font:500 12px/1 Roboto,Arial,sans-serif;letter-spacing:.2px;opacity:0;transform:translateX(-10px);transition:opacity .22s ${EASE},transform .3s ${EASE},background .15s`
      )
      b.type = 'button'
      b.title = title
      b.setAttribute('aria-label', title)
      b.append(iconSvg(d, 14), document.createTextNode(label))
      b.onmouseenter = () => (b.style.background = 'rgba(255,255,255,.16)')
      b.onmouseleave = () => (b.style.background = 'transparent')
      b.onclick = (e) => {
        e.preventDefault()
        e.stopPropagation()
        const info = getInfo()
        collapse()
        send(info)
      }
      return b
    }
    const chBtn = seg('Channel', PERSON, 'Add this channel to Pinchflat', watchChannel)
    const vdBtn = seg('Video', PLAY, 'Add this video to Pinchflat', watchVideo)
    opts.append(chBtn, vdBtn)
    root.append(toggle, opts)

    const expand = () => {
      const ch = watchChannel()
      const vd = watchVideo()
      chBtn.style.display = ch ? 'inline-flex' : 'none'
      vdBtn.style.display = vd ? 'inline-flex' : 'none'
      if (!ch && !vd) return
      open = true
      root.style.width = BTN + opts.offsetWidth + 'px'
      root.style.borderRadius = BTN / 2 + 'px'
      opts.style.transitionDelay = '0s'
      opts.style.visibility = 'visible'
      ;[...opts.children].forEach((c, i) => {
        c.style.transitionDelay = `${90 + i * 60}ms`
        c.style.opacity = '1'
        c.style.transform = 'none'
      })
      spin.style.transform = 'rotate(45deg)'
      setLabel()
    }

    toggle.onclick = (e) => {
      e.preventDefault()
      e.stopPropagation()
      if (open) collapse()
      else expand()
    }
    ;['mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach((t) =>
      root.addEventListener(t, (e) => e.stopPropagation())
    )
    setLabel()
    combos.add({ root, collapse })
    return root
  }

  const slots = [
    {
      key: 'watch',
      make: makeWatchCombo,
      get: () => (onWatch() ? watchVideo() || watchChannel() : null),
      host: () => Q('ytd-watch-metadata h1, #title h1')?.parentElement
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

  const tick = () => {
    for (const combo of combos) {
      if (!combo.root.isConnected) combos.delete(combo)
    }
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
        const b = s.make ? s.make() : makeBtn(s.label)
        b.dataset.pfKey = s.key
        Object.assign(b.style, {
          position: 'relative',
          flex: '0 0 auto',
          marginInlineStart: '10px'
        })
        if (!s.make)
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
  }

  const toast = (msg) => {
    const t = mk(
      'div',
      'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);padding:8px 14px;background:#222;color:#fff;font:13px/1.3 Roboto,Arial,sans-serif;border-radius:8px;box-shadow:0 2px 10px rgba(0,0,0,.4);z-index:2147483647;pointer-events:none',
      msg
    )
    document.body.append(t)
    setTimeout(() => t.remove(), 2200)
  }

  const canRebuildMenu = typeof GM_unregisterMenuCommand === 'function'
  let menuIds = []
  const buildMenu = () => {
    if (canRebuildMenu) menuIds.forEach((id) => GM_unregisterMenuCommand(id))
    menuIds = SETTINGS.map(([key, label]) =>
      GM_registerMenuCommand(`${cfg[key] ? '✅' : '⬜'} ${label}`, () => {
        cfg[key] = !cfg[key]
        GM_setValue(key, cfg[key])
        toast(`Pinchflat: ${label} — ${cfg[key] ? 'on' : 'off'}`)
        hide()
        tick()
        if (canRebuildMenu) buildMenu()
      })
    )
  }
  buildMenu()

  setInterval(tick, 1000)
  document.addEventListener('yt-navigate-finish', () => {
    hide()
    combos.forEach((c) => c.collapse())
    tick()
  })
})()
