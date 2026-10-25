// Run with chrome-devtools-axi run against the disposable fixture server.
import assert from 'node:assert/strict'
import { readFileSync, mkdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join } from 'node:path'

const base = new URL(process.env.RETENTION_UI_BASE_URL)
assert(
  ['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname),
  'Use a disposable loopback instance'
)
const fixture = JSON.parse(readFileSync(process.env.RETENTION_UI_FIXTURES, 'utf8'))
const browser = process.env.RETENTION_UI_BROWSER_CLI || 'chrome-devtools-axi'
const sourcePath = `/sources/${fixture.source_id}`
const retention = '[name="source[retention_period_days]"]'

async function sourceState() {
  return page.eval(async () => {
    const source = await (
      await fetch(location.pathname.replace(/\/edit$/, ''), {
        headers: { accept: 'application/json' }
      })
    ).json()
    return {
      name: source.custom_name,
      raw: source.retention_period_days,
      effective: source.effective_retention_period_days
    }
  })
}

async function preview(expected) {
  assert.equal(
    await page.eval(() => document.querySelector('#source-retention-effective').textContent.trim()),
    expected
  )
}

async function clickButton(label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = (await page.snapshot()).match(new RegExp(`uid=(\\S+) button "${escaped}"`))
  assert(match, `Button missing: ${label}`)
  await page.click(`@${match[1]}`)
}

function viewport(width) {
  execFileSync(browser, ['emulate', '--viewport', `${width}x1000x1`], { env: process.env })
}

function screenshot(name) {
  if (!process.env.RETENTION_UI_ARTIFACTS) return
  mkdirSync(process.env.RETENTION_UI_ARTIFACTS, { recursive: true })
  execFileSync(browser, ['screenshot', join(process.env.RETENTION_UI_ARTIFACTS, name)], {
    env: process.env
  })
}

await page.open(new URL(sourcePath, base).href)
assert.equal(
  (await sourceState()).name,
  '[UI test] Retention inheritance',
  'Refusing to edit an unrelated source'
)
await page.open(new URL(`${sourcePath}/edit`, base).href)
await preview('30 days (profile default)')
await page.fill(retention, '0')
await preview('No age-based cleanup (source override)')
await page.fill(retention, '1')
await preview('1 day (source override)')
await page.press('Control+A')
await page.press('Backspace')
await preview('30 days (profile default)')

await clickButton('[UI test] 30 days')
await clickButton('[UI test] 7 days')
await preview('7 days (profile default)')
await page.fill(retention, '1')
await clickButton('[UI test] 7 days')
await clickButton('[UI test] No age cleanup')
await preview('1 day (source override)')
await page.fill(retention, '1')
await page.press('Control+A')
await page.press('Backspace')
await preview('No age-based cleanup (profile default)')
await clickButton('[UI test] No age cleanup')
await clickButton('[UI test] 30 days')
await preview('30 days (profile default)')

for (const width of [320, 390, 768, 1440]) {
  viewport(width)
  assert.equal(await page.eval(() => innerWidth), width)
  await page.eval(() =>
    document
      .querySelector('#source-retention-effective')
      .parentElement.scrollIntoView({ block: 'center' })
  )
  assert(
    await page.eval(() => document.documentElement.scrollWidth <= innerWidth),
    `Form overflows at ${width}px`
  )
  screenshot(`retention-form-${width}.png`)
}
await clickButton('Save Source')
await page.wait('a[href$="/edit"]')
assert.deepEqual(await sourceState(), {
  name: '[UI test] Retention inheritance',
  raw: null,
  effective: 30
})

await page.open(new URL('/sources', base).href)
for (const width of [320, 390, 768, 1440]) {
  viewport(width)
  const geometry = await page.eval(() => {
    const visible = (el) => el.getBoundingClientRect().height > 0
    const policies = [...document.querySelectorAll('p')].filter(
      (el) => visible(el) && el.textContent.trim().startsWith('Retention:')
    )
    const clipped = policies
      .filter((el) => {
        const rect = el.getBoundingClientRect()
        return rect.left < 0 || rect.right > innerWidth || el.scrollWidth > el.clientWidth + 1
      })
      .map((el) => el.textContent.trim())
    const overflowingDeletes = [...document.querySelectorAll('article a[aria-label^="Delete "]')]
      .filter(visible)
      .filter((el) => {
        const icon = el.getBoundingClientRect()
        const card = el.closest('article').getBoundingClientRect()
        return icon.left < card.left || icon.right > card.right
      }).length
    return { width: innerWidth, clipped, overflowingDeletes, policies: policies.length }
  })
  assert.equal(geometry.width, width)
  assert(geometry.policies > 0, 'Retention policies must be visible')
  assert.deepEqual(geometry.clipped, [], `Clipped retention at ${width}px`)
  assert.equal(geometry.overflowingDeletes, 0, `Delete action outside its card at ${width}px`)
  screenshot(`retention-sources-${width}.png`)
}
await clickButton('Poster grid')
await page.wait('#source-poster-grid')
for (const width of [320, 390, 768, 1440]) {
  viewport(width)
  const policies = await page.eval(() => {
    return [...document.querySelectorAll('#source-poster-grid p')]
      .filter((el) => el.textContent.trim().startsWith('Retention:'))
      .map((el) => ({
        text: el.textContent.trim(),
        width: el.clientWidth,
        contentWidth: el.scrollWidth
      }))
  })
  assert.equal(policies.length, 3)
  assert(policies.some((policy) => policy.text.includes('30 days (profile default)')))
  assert(policies.some((policy) => policy.text.includes('No age-based cleanup (source override)')))
  assert(policies.some((policy) => policy.text.includes('1 day (source override)')))
  assert(
    policies.every((policy) => policy.width + 1 >= policy.contentWidth),
    `Grid policy overflows at ${width}px`
  )
  screenshot(`retention-grid-${width}.png`)
}
console.log(
  'PASS: live inheritance, overrides, profile changes, blank save and responsive source actions'
)
