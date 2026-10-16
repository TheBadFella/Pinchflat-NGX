import assert from 'node:assert/strict'
import test from 'node:test'
import { datePicker } from '../../assets/js/date_picker.mjs'

test('calendar fits narrow screens and gives wider touch layouts room for 44px days', (t) => {
  const originalWindow = globalThis.window
  const originalDocument = globalThis.document
  t.after(() => {
    globalThis.window = originalWindow
    globalThis.document = originalDocument
  })

  globalThis.document = {
    querySelector: () => ({ getBoundingClientRect: () => ({ bottom: 64 }) })
  }

  for (const [viewport, coarse, expectedWidth] of [
    [320, false, 318],
    [390, false, 360],
    [768, false, 304],
    [768, true, 360]
  ]) {
    globalThis.window = {
      innerWidth: viewport,
      innerHeight: 740,
      matchMedia: () => ({ matches: coarse })
    }
    const picker = datePicker('2026-10-15', '2026-10-15')
    picker.$refs = {
      trigger: {
        parentElement: { getBoundingClientRect: () => ({ left: viewport - 150, bottom: 600 }) }
      },
      panel: { style: {}, scrollHeight: 420 }
    }
    picker.position()

    const width = Number.parseFloat(picker.panelStyle.width)
    const left = Number.parseFloat(picker.panelStyle.left)
    assert.equal(width, expectedWidth)
    assert.ok(left >= 0 && left + width <= viewport)
    assert.ok(Number.parseFloat(picker.panelStyle.top) >= 72)
    if (viewport < 640 || coarse) assert.ok((width - 10) / 7 >= 44)
  }
})

test('opening waits for the calendar days to render before measuring its height', (t) => {
  const saved = {
    window: globalThis.window,
    document: globalThis.document,
    frame: globalThis.requestAnimationFrame
  }
  t.after(() => {
    globalThis.window = saved.window
    globalThis.document = saved.document
    globalThis.requestAnimationFrame = saved.frame
  })
  globalThis.window = { innerWidth: 320, innerHeight: 740, matchMedia: () => ({ matches: false }) }
  globalThis.document = { querySelector: () => ({ getBoundingClientRect: () => ({ bottom: 64 }) }) }
  let renderFrame
  globalThis.requestAnimationFrame = (callback) => {
    renderFrame = callback
  }
  const panel = { style: {}, scrollHeight: 0 }
  const picker = datePicker('2026-10-15', '2026-10-15')
  picker.$refs = {
    panel,
    trigger: { parentElement: { getBoundingClientRect: () => ({ left: 16, bottom: 600 }) } }
  }
  picker.$nextTick = (callback) => callback()
  picker.focusDay = () => {}
  picker.toggle()
  panel.scrollHeight = 420
  renderFrame()
  assert.ok(Number.parseFloat(picker.panelStyle.top) + panel.scrollHeight <= 724)
})

test('first opening measures the height at the final panel width', (t) => {
  const saved = { window: globalThis.window, document: globalThis.document }
  t.after(() => {
    globalThis.window = saved.window
    globalThis.document = saved.document
  })
  globalThis.window = { innerWidth: 390, innerHeight: 844, matchMedia: () => ({ matches: false }) }
  globalThis.document = { querySelector: () => ({ getBoundingClientRect: () => ({ bottom: 72 }) }) }
  const picker = datePicker('2020-01-01', '2026-10-16')
  const panel = {
    style: {},
    get scrollHeight() {
      return this.style.width === '360px' ? 422 : 281
    }
  }
  picker.$refs = {
    panel,
    trigger: { parentElement: { getBoundingClientRect: () => ({ left: 17, bottom: 539 }) } }
  }
  picker.position()
  assert.ok(Number.parseFloat(picker.panelStyle.top) + 422 <= 828)
})
