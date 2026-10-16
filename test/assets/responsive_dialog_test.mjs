import { test } from 'node:test'
import assert from 'node:assert/strict'
import { responsiveDialog } from '../../assets/js/responsive_dialog.mjs'

test('filter sheet survives LiveView patches, preserves dates and restores focus on close', () => {
  const handlers = {}
  const dates = { open: false }
  let focused = 0
  const classes = new Set()
  globalThis.document = {
    activeElement: { focus: () => focused++ },
    body: { classList: { add: (x) => classes.add(x), remove: (x) => classes.delete(x) } }
  }
  globalThis.window = { innerWidth: 390, addEventListener() {}, removeEventListener() {} }
  const el = {
    open: false,
    contains: () => false,
    showModal() {
      this.open = true
    },
    close() {
      this.open = false
      handlers.close()
    },
    querySelector: (selector) => (selector === 'details' ? dates : { focus: () => focused++ }),
    addEventListener: (name, fn) => {
      handlers[name] = fn
    },
    removeEventListener() {}
  }
  const hook = { ...responsiveDialog, el }
  try {
    hook.mounted()
    handlers['open-dialog']({ detail: { custom: true } })
    assert.equal(el.open, true)
    assert.equal(dates.open, true)
    hook.beforeUpdate()
    el.open = false
    dates.open = false
    hook.updated()
    assert.equal(el.open, true)
    assert.equal(dates.open, true)
    handlers.close()
    assert.equal(classes.has('overflow-hidden'), true)
    handlers['close-dialog']()
    assert.equal(classes.has('overflow-hidden'), false)
    assert.equal(focused, 2)
    hook.destroyed()
  } finally {
    delete globalThis.document
    delete globalThis.window
  }
})
