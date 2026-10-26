import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import vm from 'node:vm'

const root = new URL('../../', import.meta.url)
const layout = readFileSync(
  new URL('lib/pinchflat_web/components/layouts/root.html.heex', root),
  'utf8'
)
const bootstrap = layout.match(/<script>([\s\S]*?)<\/script>/)[1]
const helpers = readFileSync(new URL('assets/js/alpine_helpers.js', root), 'utf8')

function browser(saved, blocked = false) {
  const values = new Map(saved === undefined ? [] : [['sidebarCollapsed', saved]])
  const context = vm.createContext({
    document: { documentElement: { dataset: {} } },
    localStorage: {
      getItem(key) {
        if (blocked) throw new Error('Storage is blocked')
        return values.get(key) ?? null
      },
      setItem(key, value) {
        if (blocked) throw new Error('Storage is blocked')
        values.set(key, value)
      }
    }
  })
  context.window = context
  vm.runInContext(bootstrap, context)
  vm.runInContext(helpers, context)
  return { context, values }
}

test('restores collapsed layout before Alpine starts and preserves deliberate changes', () => {
  const { context, values } = browser('true')
  assert.equal(context.document.documentElement.dataset.sidebarCollapsed, 'true')
  assert.equal(context.getSidebarCollapsed(), true)
  context.setSidebarCollapsed(false)
  assert.equal(context.document.documentElement.dataset.sidebarCollapsed, 'false')
  assert.equal(values.get('sidebarCollapsed'), 'false')
  context.setSidebarCollapsed(true)
  assert.equal(context.getSidebarCollapsed(), true)
  assert.equal(values.get('sidebarCollapsed'), 'true')
})

test('missing or malformed preferences start expanded', () => {
  for (const saved of [undefined, 'false', 'invalid']) {
    const { context } = browser(saved)
    assert.equal(context.document.documentElement.dataset.sidebarCollapsed, 'false')
    assert.equal(context.getSidebarCollapsed(), false)
  }
})

test('blocked storage still allows the sidebar to open and close', () => {
  const { context } = browser('true', true)
  assert.equal(context.getSidebarCollapsed(), false)
  context.setSidebarCollapsed(true)
  assert.equal(context.getSidebarCollapsed(), true)
  context.setSidebarCollapsed(false)
  assert.equal(context.getSidebarCollapsed(), false)
})

test('old backup bookmarks open the standalone backups page', () => {
  for (const [pathname, expected] of [
    ['/settings', '/backups'],
    ['/custom_prefix/settings', '/custom_prefix/backups']
  ]) {
    for (const hash of ['#postgres-backups', '#backups']) {
      const { context } = browser()
      let destination
      context.location = {
        pathname,
        hash,
        replace: (url) => {
          destination = url
        }
      }
      context.settingsPage().applyHash()
      assert.equal(destination, expected)
    }
  }
})
