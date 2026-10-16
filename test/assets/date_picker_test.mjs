import assert from 'node:assert/strict'
import test from 'node:test'
import { datePicker } from '../../assets/js/date_picker.mjs'

test('calendar shows leap day and preserves dates without timezone conversion', () => {
  const picker = datePicker('2024-02-29')
  picker.init()
  const days = picker.days()
  assert.equal(days.length, 42)
  assert.equal(days[0].iso, '2024-01-28')
  assert.equal(days.find((day) => day.iso === '2024-02-29').number, 29)
  assert.equal(picker.focused, '2024-02-29')
})

test('month and keyboard navigation cross year and month boundaries', () => {
  const picker = datePicker('2024-12-31')
  picker.init()
  picker.focusDay = () => {}
  picker.navigate({ key: 'ArrowRight', preventDefault() {} })
  assert.equal(picker.focused, '2025-01-01')
  assert.equal(picker.month, 0)
  picker.changeMonth(-1)
  assert.equal(picker.focused, '2024-12-01')
  picker.navigate({ key: 'End', preventDefault() {} })
  assert.equal(picker.focused, '2024-12-07')
})

test('invalid typed dates open the current month without changing the submitted value', () => {
  const picker = datePicker('2024-02-31')
  picker.init()
  assert.equal(picker.value, '2024-02-31')
  assert.equal(picker.year, new Date().getFullYear())
})

test('invalid input opens today in the configured timezone instead of the browser date', () => {
  const picker = datePicker('invalid', '2024-12-31')
  picker.init()
  assert.equal(picker.focused, '2024-12-31')
  assert.equal(picker.value, 'invalid')
})
