// Run with chrome-devtools-axi run against the disposable fixture server.
import assert from 'node:assert/strict'
import { readFileSync, mkdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join } from 'node:path'

const base = new URL(process.env.LIBRARY_UI_BASE_URL)
assert(
  ['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname),
  'Use a disposable loopback instance'
)
const fixture = JSON.parse(readFileSync(process.env.LIBRARY_UI_FIXTURES, 'utf8'))
const browser = process.env.LIBRARY_UI_BROWSER_CLI || 'chrome-devtools-axi'

function emitViewport(width, touch = false) {
  const spec = touch ? `${width}x1000x3,mobile,touch` : `${width}x1000x1`
  execFileSync(browser, ['emulate', '--viewport', spec], { env: process.env })
}

function screenshot(name) {
  if (!process.env.LIBRARY_UI_ARTIFACTS) return
  mkdirSync(process.env.LIBRARY_UI_ARTIFACTS, { recursive: true })
  execFileSync(browser, ['screenshot', join(process.env.LIBRARY_UI_ARTIFACTS, name)], {
    env: process.env
  })
}

async function open(path) {
  await page.open(new URL(path, base).href)
  await page.wait(250)
}

function noHorizontalScroll() {
  return page.eval(() => document.documentElement.scrollWidth <= innerWidth + 1)
}

async function assertPages(width) {
  const pages = [
    ['/', 'home-latest'],
    ['/?tab=downloaded', 'home-downloaded'],
    ['/activity', 'activity'],
    ['/sources', 'sources-grid'],
    ['/sources?view=table', 'sources-table'],
    [`/sources/${fixture.long_playlist_id}`, 'playlist-default']
  ]

  for (const [path, name] of pages) {
    await open(path)
    assert(await noHorizontalScroll(), `${path} overflows horizontally at ${width}px`)
    screenshot(`${name}-${width}.png`)
  }

  await open(`/sources/${fixture.channel_id}?tab=videos`)
  assert(await noHorizontalScroll(), `Videos list overflows horizontally at ${width}px`)
  screenshot(`channel-videos-list-${width}.png`)

  const switchedToGrid = await page.eval(() => {
    const grid = [...document.querySelectorAll('button[aria-label="Grid"]')].find(
      (button) => button.getBoundingClientRect().width > 0
    )
    if (!grid) return false
    grid.click()
    return true
  })

  if (switchedToGrid) {
    await page.wait(250)
    assert(await noHorizontalScroll(), `Videos grid overflows horizontally at ${width}px`)
    screenshot(`channel-videos-grid-${width}.png`)

    await page.eval(() => {
      const list = [...document.querySelectorAll('button[aria-label="List"]')].find(
        (button) => button.getBoundingClientRect().width > 0
      )
      if (list) list.click()
    })
    await page.wait(200)
  }
}

async function assertThumbnails(width) {
  await open('/?tab=downloaded')

  const ids = JSON.stringify({
    realUuid: fixture.real_thumbnail_uuid,
    missingId: fixture.missing_thumbnail_item_id,
    nilId: fixture.nil_thumbnail_item_id
  })

  const result = await page.eval(
    new Function(`
      return (async () => {
        const ids = ${ids}
        const rowFor = (id) =>
          document.querySelector('a[href$="/media/' + id + '"]')?.closest('tr, article') || null
        const frameFor = (row) => row?.querySelector('div.aspect-video') || null
        const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

        const realSrc = '/media/' + ids.realUuid + '/episode_image'
        const realImg = document.querySelector('img[src="' + realSrc + '"]')
        if (realImg) {
          realImg.scrollIntoView({ block: 'center' })
          await realImg.decode().catch(() => {})
        }
        await wait(200)

        const missingRow = rowFor(ids.missingId)
        missingRow?.scrollIntoView({ block: 'center' })
        await wait(400)

        const nilRow = rowFor(ids.nilId)
        nilRow?.scrollIntoView({ block: 'center' })
        await wait(200)

        const placeholderVisible = (frame) => {
          const icon = frame?.querySelector('[data-icon="hero-film"]')
          if (!icon) return false
          const rect = icon.getBoundingClientRect()
          return rect.width > 0 && rect.height > 0 && getComputedStyle(icon).display !== 'none'
        }

        const missingFrame = frameFor(missingRow)
        const missingImg = missingFrame?.querySelector('img')

        return {
          realLoaded: Boolean(realImg && realImg.naturalWidth > 0),
          missingImageHidden: Boolean(missingImg && getComputedStyle(missingImg).display === 'none'),
          missingPlaceholder: placeholderVisible(missingFrame),
          nilHasNoImage: Boolean(frameFor(nilRow) && !frameFor(nilRow).querySelector('img')),
          nilPlaceholder: placeholderVisible(frameFor(nilRow))
        }
      })()
    `)
  )

  assert(result.realLoaded, `Real thumbnail did not load at ${width}px`)
  assert(result.missingImageHidden, `Missing thumbnail image stayed visible at ${width}px`)
  assert(result.missingPlaceholder, `Missing thumbnail placeholder is not visible at ${width}px`)
  assert(result.nilHasNoImage, `Nil thumbnail unexpectedly rendered an image at ${width}px`)
  assert(result.nilPlaceholder, `Nil thumbnail placeholder is not visible at ${width}px`)
  screenshot(`thumbnails-${width}.png`)
}

async function actionHeader(path) {
  await open(path)
  return page.eval(() =>
    [...document.querySelectorAll('th')].some((header) => header.textContent.trim() === 'Action')
  )
}

async function assertActionColumn(width) {
  if (width < 768) return
  assert.equal(await actionHeader('/'), true, `Action header missing on Home at ${width}px`)
  assert.equal(
    await actionHeader('/?tab=downloaded'),
    false,
    `Action header unexpectedly present on Downloaded at ${width}px`
  )
  assert.equal(
    await actionHeader(`/sources/${fixture.channel_id}?tab=videos`),
    false,
    `Action header unexpectedly present on Videos at ${width}px`
  )
}

async function assertTouchTargets(width) {
  await open('/sources?view=table')

  const targets = await page.eval(() => {
    const visible = (el) => {
      const rect = el.getBoundingClientRect()
      return rect.width > 0 && rect.height > 0 && getComputedStyle(el).visibility !== 'hidden'
    }
    const rows = [...document.querySelectorAll('#source-table tbody tr, article')].filter(visible)

    return rows.flatMap((row) =>
      [...row.querySelectorAll('button, a, [role=button]')].filter(visible).map((el) => {
        const rect = el.getBoundingClientRect()
        return {
          label: (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 60),
          width: rect.width,
          height: rect.height
        }
      })
    )
  })

  assert(targets.length > 0, `No source row controls at ${width}px`)
  for (const target of targets) {
    assert(
      target.width >= 44 && target.height >= 44,
      `${target.label} target ${target.width}x${target.height} below 44px at ${width}px`
    )
  }

  const menu = await page.eval(async () => {
    const trigger = document.querySelector('button[aria-label^="More actions for"]')
    trigger.focus()
    trigger.click()
    await new Promise((resolve) => setTimeout(resolve, 150))
    const items = [...trigger.closest('div.relative').querySelectorAll('button[type=submit]')]
    const result = items.map((button) => {
      const rect = button.getBoundingClientRect()
      return { text: button.textContent.trim(), width: rect.width, height: rect.height }
    })
    trigger.click()
    return result
  })

  for (const item of menu) {
    assert(
      item.width >= 44 && item.height >= 44,
      `${item.text} menu target ${item.width}x${item.height} below 44px at ${width}px`
    )
  }
  screenshot(`source-rows-touch-${width}.png`)
}

async function assertRowMenuKeyboard() {
  await open('/sources?view=table')

  await page.eval(() => {
    const trigger = document.querySelector('button[aria-label^="More actions for"]')
    trigger.focus()
  })
  await page.press('Enter')
  await page.wait(200)

  assert(
    await page.eval(() => {
      const trigger = document.querySelector('button[aria-label^="More actions for"]')
      const menu = trigger.closest('div.relative').querySelector('ul')
      return getComputedStyle(menu).display !== 'none' && menu.getBoundingClientRect().height > 0
    }),
    'Enter did not open the row menu'
  )

  const focused = []
  for (let index = 0; index < 4; index += 1) {
    await page.press('Tab')
    focused.push(await page.eval(() => (document.activeElement?.textContent || '').trim()))
  }

  for (const label of ['Start all', 'Pause all', 'Stop all', 'Delete source']) {
    assert(
      focused.includes(label),
      `Tab order did not reach ${label}; reached ${JSON.stringify(focused)}`
    )
  }

  await page.press('Escape')
  await page.wait(200)
  assert(
    await page.eval(() => {
      const trigger = document.querySelector('button[aria-label^="More actions for"]')
      const menu = trigger.closest('div.relative').querySelector('ul')
      return (
        document.activeElement === trigger &&
        (getComputedStyle(menu).display === 'none' || menu.getBoundingClientRect().height === 0)
      )
    }),
    'Escape did not close the row menu and restore focus'
  )

  const before = await page.eval(() => location.href)
  await page.eval(() => {
    window.__confirmCancelled = false
    window.__submitted = false
    window.confirm = () => {
      window.__confirmCancelled = true
      return false
    }
    const trigger = document.querySelector('button[aria-label^="More actions for"]')
    trigger.focus()
    trigger.click()
  })
  await page.wait(200)

  const paused = await page.eval(() => {
    const pause = [...document.querySelectorAll('button[type=submit]')].find(
      (button) => button.textContent.trim() === 'Pause all'
    )
    if (!pause) return false
    pause.closest('form').addEventListener('submit', () => {
      window.__submitted = true
    })
    pause.focus()
    return true
  })
  assert(paused, 'Pause action missing from the row menu')

  await page.press('Enter')
  await page.wait(300)

  const confirmed = await page.eval(() => ({
    cancelled: window.__confirmCancelled,
    submitted: window.__submitted,
    href: location.href
  }))
  assert(confirmed.cancelled, 'Pause did not ask for confirmation')
  assert(!confirmed.submitted, 'Cancelling the confirmation still submitted the Pause form')
  assert.equal(confirmed.href, before, 'Cancelling the confirmation navigated away')
  screenshot('row-menu-keyboard.png')
}

async function assertEmptyHome() {
  await open('/')
  const state = await page.eval(() => ({
    sentence: document.body.textContent.includes('Nothing was indexed in the past 24 hours.'),
    week: document.body.textContent.includes('Show past 7 days'),
    downloaded: document.body.textContent.includes('View downloaded'),
    overflow: document.documentElement.scrollWidth > innerWidth + 1
  }))

  assert(state.sentence, 'Default empty state does not name the 24 hour comparison')
  assert(state.week, 'Show past 7 days action is missing')
  assert(state.downloaded, 'View downloaded action is missing')
  assert(!state.overflow, 'Empty Home overflows horizontally')
  screenshot('home-empty-390.png')
}

if (fixture.mode === 'empty') {
  emitViewport(390, true)
  await assertEmptyHome()
  console.log('PASS: empty library Home state')
} else {
  for (const width of [320, 390, 768, 1440]) {
    const touch = width <= 390
    emitViewport(width, touch)
    await assertPages(width)
    await assertThumbnails(width)
    await assertActionColumn(width)
    if (touch) await assertTouchTargets(width)
    screenshot(`library-overview-${width}.png`)
  }

  emitViewport(768)
  await assertRowMenuKeyboard()
  console.log('PASS: library pages, thumbnails, action column, touch targets and row menu keyboard')
}
