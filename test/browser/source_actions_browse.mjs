// Run with chrome-devtools-axi run against the disposable fixture server.
import assert from 'node:assert/strict'
import { readFileSync, mkdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join } from 'node:path'

const base = new URL(process.env.SOURCE_ACTIONS_UI_BASE_URL)
assert(
  ['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname),
  'Use a disposable loopback instance'
)
const fixture = JSON.parse(readFileSync(process.env.SOURCE_ACTIONS_UI_FIXTURES, 'utf8'))
const browser = process.env.SOURCE_ACTIONS_UI_BROWSER_CLI || 'chrome-devtools-axi'

function emitViewport(width, touch = false) {
  const spec = touch ? `${width}x1000x3,mobile,touch` : `${width}x1000x1`
  execFileSync(browser, ['emulate', '--viewport', spec], { env: process.env })
}

function screenshot(name) {
  if (!process.env.SOURCE_ACTIONS_UI_ARTIFACTS) return
  mkdirSync(process.env.SOURCE_ACTIONS_UI_ARTIFACTS, { recursive: true })
  execFileSync(browser, ['screenshot', join(process.env.SOURCE_ACTIONS_UI_ARTIFACTS, name)], {
    env: process.env
  })
}

async function open(path) {
  await page.open(new URL(path, base).href)
}

async function clickButton(label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = (await page.snapshot()).match(new RegExp(`uid=(\\S+) button "${escaped}"`))
  assert(match, `Button missing: ${label}`)
  await page.click(`@${match[1]}`)
}
// Source action glyphs must sit at the centre of their button content box and
// stay aligned with the neighbouring edit/delete controls in the same row.
async function measureActions() {
  return page.eval(() => {
    const visible = (el) => {
      const rect = el.getBoundingClientRect()
      return rect.width > 0 && rect.height > 0 && getComputedStyle(el).visibility !== 'hidden'
    }
    const center = (rect) => ({
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2
    })

    const selector = ['Start all', 'Pause all', 'Stop all']
      .map((label) => `button[aria-label="${label}"]`)
      .join(', ')

    return [...document.querySelectorAll(selector)].filter(visible).map((button) => {
      const icon = button.querySelector('span[data-icon]')
      const neighbours = [...button.closest('form').parentElement.children]
        .filter((el) => el !== button.closest('form') && visible(el))
        .map((el) => center(el.getBoundingClientRect()))

      const row = button.closest('tr, article')
      const rowControls = row
        ? [...row.querySelectorAll('a[aria-label="Edit"], a[aria-label^="Delete"]')].filter(visible)
        : []
      const rowControlsCenter = rowControls.map((el) => center(el.getBoundingClientRect()))

      const buttonRect = button.getBoundingClientRect()
      const iconCenter = icon ? center(icon.getBoundingClientRect()) : null
      const buttonCenter = center(buttonRect)

      return {
        width: buttonRect.width,
        height: buttonRect.height,
        iconDeltaX: iconCenter ? Math.abs(iconCenter.x - buttonCenter.x) : null,
        iconDeltaY: iconCenter ? Math.abs(iconCenter.y - buttonCenter.y) : null,
        neighbourDeltaY: neighbours.length
          ? Math.min(...neighbours.map((n) => Math.abs(n.y - buttonCenter.y)))
          : 0,
        rowControlDeltaY: rowControlsCenter.length
          ? Math.min(...rowControlsCenter.map((n) => Math.abs(n.y - buttonCenter.y)))
          : 0,
        insideViewport: buttonRect.left >= -1 && buttonRect.right <= innerWidth + 1,
        label: button.getAttribute('aria-label')
      }
    })
  })
}
async function assertActions(width, { touch = false, minTarget = 0 } = {}) {
  emitViewport(width, touch)
  await page.wait(150)
  const actions = await measureActions()
  assert(actions.length > 0, `No visible start actions at ${width}px`)
  const labels = new Set(actions.map((action) => action.label))
  for (const label of ['Start all', 'Pause all', 'Stop all']) {
    assert(labels.has(label), `Missing ${label} action at ${width}px`)
  }
  for (const action of actions) {
    assert(action.iconDeltaX !== null, `Missing icon for ${action.label}`)
    assert(
      action.iconDeltaX <= 2,
      `Icon off-centre horizontally by ${action.iconDeltaX}px at ${width}px`
    )
    assert(
      action.iconDeltaY <= 2,
      `Icon off-centre vertically by ${action.iconDeltaY}px at ${width}px`
    )
    assert(
      action.neighbourDeltaY <= 3,
      `Action group not aligned with neighbours (${action.neighbourDeltaY}px) at ${width}px`
    )
    if (width >= 768) {
      assert(
        action.rowControlDeltaY <= 8,
        `Action not aligned with row controls (${action.rowControlDeltaY}px) at ${width}px`
      )
    }
    assert(action.insideViewport, `Action outside viewport at ${width}px`)
    if (minTarget) {
      assert(
        action.width >= minTarget && action.height >= minTarget,
        `${action.label} target ${action.width}x${action.height} below ${minTarget}px at ${width}px`
      )
    }
  }
  assert(
    await page.eval(() => document.documentElement.scrollWidth <= innerWidth + 1),
    `Page overflows horizontally at ${width}px`
  )
  screenshot(`source-actions-${width}.png`)
}
await open('/sources')
const visibleNames = await page.eval(() =>
  [...document.querySelectorAll('article, tbody tr')].map((el) => el.textContent)
)
assert(
  visibleNames.some((text) => text.includes('[UI test] Short action source')),
  'Fixture sources are missing; refusing to inspect an unrelated library'
)
assert(
  visibleNames.some((text) => text.includes('[UI test] A very long source name')),
  'Long fixture source is missing'
)

const formActions = await page.eval(() =>
  [...document.querySelectorAll('form[action]')]
    .map((form) => form.getAttribute('action'))
    .filter((action) => /\/(start|pause|stop)_all$/.test(action))
)
assert(formActions.some((action) => action.endsWith('/start_all')))
assert(formActions.some((action) => action.endsWith('/pause_all')))
assert(formActions.some((action) => action.endsWith('/stop_all')))

for (const width of [320, 390, 768, 1440]) {
  const touch = width <= 390
  await assertActions(width, { touch, minTarget: touch ? 44 : 0 })
}
await open('/browse')
const pasteState = await page.eval(() => {
  const buttons = [...document.querySelectorAll('#open-paste-url-button')]
  const searchForm = document.querySelector('#browse_search_form')
  return {
    count: buttons.length,
    insideSearch: Boolean(searchForm && searchForm.querySelector('#open-paste-url-button')),
    text: buttons[0] ? buttons[0].textContent.trim() : '',
    type: buttons[0] ? buttons[0].getAttribute('type') : null
  }
})
assert.equal(pasteState.count, 1, 'Exactly one Paste URL action must render')
assert(pasteState.insideSearch, 'Paste URL must live in the search action area')
assert.match(pasteState.text, /Paste URL/)
assert.equal(pasteState.type, 'button')

await page.fill('#browse_query', 'kept query')
await page.wait(150)

const beforeOpen = await page.eval(() => ({
  query: document.querySelector('#browse_query').value,
  profile: document.querySelector('#profile_selector').value,
  href: location.href
}))
assert.equal(beforeOpen.query, 'kept query')
assert.equal(beforeOpen.profile, String(fixture.profile_id))

await page.eval(() => {
  window.__browseSubmitted = false
  document.querySelector('#browse_search_form').addEventListener(
    'submit',
    () => {
      window.__browseSubmitted = true
    },
    true
  )
})

await clickButton('Paste URL')
await page.wait(250)

const afterOpen = await page.eval(() => ({
  query: document.querySelector('#browse_query').value,
  profile: document.querySelector('#profile_selector').value,
  dialogOpen: Boolean(document.querySelector('#paste-url-dialog')),
  submitted: window.__browseSubmitted,
  href: location.href
}))
assert.equal(afterOpen.dialogOpen, true)
assert.equal(afterOpen.submitted, false, 'Opening Paste URL must not submit the search form')
assert.equal(afterOpen.href, beforeOpen.href, 'Opening Paste URL must not navigate')
assert.equal(afterOpen.query, beforeOpen.query)
assert.equal(afterOpen.profile, beforeOpen.profile)

await page.press('Escape')
await page.wait(300)
assert(
  await page.eval(
    () =>
      !document.querySelector('#paste-url-dialog') &&
      document.activeElement &&
      document.activeElement.id === 'open-paste-url-button'
  ),
  'Closing the dialog must restore focus to the relocated Paste URL button'
)
for (const width of [320, 390, 768, 1440]) {
  const touch = width <= 390
  emitViewport(width, touch)
  await page.wait(150)
  const layout = await page.eval(() => {
    const input = document.querySelector('#browse_query').getBoundingClientRect()
    const paste = document.querySelector('#open-paste-url-button').getBoundingClientRect()
    const search = document
      .querySelector('#browse_search_form button[type="submit"]')
      .getBoundingClientRect()
    return {
      inputWidth: input.width,
      pasteVisible: paste.width > 0 && paste.height > 0,
      overflow: document.documentElement.scrollWidth > innerWidth + 1,
      searchTop: search.top,
      pasteTop: paste.top,
      pasteRight: paste.right
    }
  })
  assert(layout.inputWidth >= 140, `Search input too narrow at ${width}px`)
  assert(layout.pasteVisible, `Paste URL hidden at ${width}px`)
  assert(!layout.overflow, `Browse page overflows at ${width}px`)
  assert(layout.pasteRight <= width + 1, `Paste URL clipped at ${width}px`)
  if (width >= 768) {
    assert(
      Math.abs(layout.pasteTop - layout.searchTop) <= 2,
      `Paste URL is not beside Search at ${width}px`
    )
  }
  screenshot(`browse-actions-${width}.png`)
}

console.log('PASS: source action centring, touch targets, Paste URL placement and dialog focus')
