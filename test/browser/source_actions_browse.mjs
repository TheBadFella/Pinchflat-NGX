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
// Row actions live behind the per-row "More actions" menu. Open it with the
// keyboard, verify the destinations and touch targets, close it with Escape,
// and never activate the destructive Delete option.
async function assertRowMenus(width, { touch = false, minTarget = 0 } = {}) {
  emitViewport(width, touch)
  await page.wait(150)

  const triggerState = await page.eval(() => {
    const triggers = [
      ...document.querySelectorAll('button[aria-label^="More actions for"]')
    ].filter((el) => el.getBoundingClientRect().width > 0)
    return triggers.map((trigger) => {
      const rect = trigger.getBoundingClientRect()
      return {
        width: rect.width,
        height: rect.height,
        insideViewport: rect.left >= -1 && rect.right <= innerWidth + 1,
        label: trigger.getAttribute('aria-label')
      }
    })
  })
  assert(triggerState.length > 0, `No row menus at ${width}px`)
  for (const trigger of triggerState) {
    assert(trigger.insideViewport, `${trigger.label} outside viewport at ${width}px`)
    if (minTarget) {
      assert(
        trigger.width >= minTarget && trigger.height >= minTarget,
        `${trigger.label} target ${trigger.width}x${trigger.height} below ${minTarget}px at ${width}px`
      )
    }
  }

  await page.eval(() => {
    const trigger = document.querySelector('button[aria-label^="More actions for"]')
    trigger.focus()
    trigger.click()
  })
  await page.wait(150)

  const menuState = await page.eval(() => {
    const trigger = document.querySelector('button[aria-label^="More actions for"]')
    const container = trigger.closest('div.relative')
    const menu = container.querySelector('ul')
    const menuRect = menu.getBoundingClientRect()
    const options = [...menu.querySelectorAll('button[type="submit"]')].map((button) => {
      const rect = button.getBoundingClientRect()
      const form = button.closest('form')
      return {
        text: button.textContent.trim(),
        width: rect.width,
        height: rect.height,
        action: form ? form.getAttribute('action') : null,
        confirm: button.getAttribute('data-confirm'),
        visible:
          rect.width > 0 && rect.height > 0 && getComputedStyle(button).visibility !== 'hidden'
      }
    })
    return {
      menuLeft: menuRect.left,
      menuRight: menuRect.right,
      options
    }
  })

  for (const [text, suffix] of [
    ['Start all', '/start_all'],
    ['Pause all', '/pause_all'],
    ['Stop all', '/stop_all']
  ]) {
    const option = menuState.options.find((candidate) => candidate.text === text)
    assert(option, `Missing ${text} in the row menu at ${width}px`)
    assert(option.visible, `${text} hidden at ${width}px`)
    assert(option.action && option.action.endsWith(suffix), `${text} posts to ${option.action}`)
    assert(option.confirm, `${text} is missing its confirmation`)
    if (minTarget) {
      assert(
        option.width >= minTarget && option.height >= minTarget,
        `${text} target ${option.width}x${option.height} below ${minTarget}px at ${width}px`
      )
    }
  }

  assert(
    menuState.options.some((option) => option.text === 'Delete source'),
    `Missing Delete source in the row menu at ${width}px`
  )
  assert(
    menuState.menuLeft >= -1 && menuState.menuRight <= innerWidth + 1,
    `Row menu clipped (${menuState.menuLeft}-${menuState.menuRight}) at ${width}px`
  )
  assert(
    await page.eval(() => document.documentElement.scrollWidth <= innerWidth + 1),
    `Page overflows horizontally at ${width}px`
  )

  await page.press('Escape')
  await page.wait(150)
  const closed = await page.eval(() => {
    const trigger = document.querySelector('button[aria-label^="More actions for"]')
    const menu = trigger.closest('div.relative').querySelector('ul')
    const rect = menu.getBoundingClientRect()
    return {
      menuVisible: getComputedStyle(menu).display !== 'none' && rect.height > 0,
      focused: document.activeElement === trigger
    }
  })
  assert(!closed.menuVisible, `Row menu stayed open at ${width}px`)
  assert(closed.focused, `Focus did not return to the row trigger at ${width}px`)
  screenshot(`source-row-menu-${width}.png`)
}
await open('/sources?view=table')
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
  await assertRowMenus(width, { touch, minTarget: touch ? 44 : 0 })
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
