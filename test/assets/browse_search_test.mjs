import assert from 'node:assert/strict'
import test from 'node:test'
import { browseSearch } from '../../assets/js/browse_search.mjs'

test('search state restores on connection and preserves prefixed URLs safely', () => {
  const original = globalThis.window
  let handler
  let restored
  let written
  globalThis.window = {
    location: { href: 'https://owned.example/pf/browse?q=日本語&profile=7&url=old#results' },
    history: { replaceState: (_state, _title, url) => (written = url) }
  }
  try {
    const hook = {
      ...browseSearch,
      handleEvent: (name, callback) => {
        assert.equal(name, 'browse:remember')
        handler = callback
      },
      pushEvent: (name, params) => {
        assert.equal(name, 'restore_search')
        restored = params
      }
    }
    hook.mounted()
    assert.deepEqual(restored, { q: '日本語', tab: 'videos', profile: '7' })
    handler({ q: 'quotes " & <script>', tab: 'channels', profile: 9 })
    const result = new URL(written, 'https://owned.example')
    assert.equal(result.pathname, '/pf/browse')
    assert.equal(result.searchParams.get('q'), 'quotes " & <script>')
    assert.equal(result.searchParams.get('profile'), '9')
    assert.equal(result.searchParams.get('url'), null)
    assert.equal(result.hash, '#results')
    hook.reconnected()
    assert.deepEqual(restored, { q: '日本語', tab: 'videos', profile: '7' })
  } finally {
    globalThis.window = original
  }
})
