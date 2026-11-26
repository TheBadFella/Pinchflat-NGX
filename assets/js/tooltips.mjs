// Styled tooltips from the `tooltip` component (text_components.ex).
//
// A tip opens in the browser's top layer, so a scrolling table or a neighbouring card can't clip
// or cover it. It is centred on its trigger, kept inside the viewport and flipped above or below
// when there isn't room. Hover or keyboard focus opens it; on a touch screen, tapping something that
// isn't a control toggles it. A click, scroll or Escape closes it.

const GAP = 12
const EDGE = 8
const ARROW_INSET = 12
const CONTROLS = 'a, button, input, select, textarea, label, summary, [role="button"]'

let current = null
// A clicked trigger stays quiet until the pointer leaves it.
let suppressed = null

function tipFor(anchor) {
  return anchor.querySelector(':scope > [data-tooltip]')
}

function show(anchor) {
  const tip = tipFor(anchor)
  if (!tip) return
  if (current && current.tip === tip) return
  hide()

  tip.classList.remove('hidden')
  if (typeof tip.showPopover === 'function') {
    try {
      tip.showPopover()
    } catch (_error) {
      // Already open, or detached by a LiveView patch.
    }
  }

  current = { anchor, tip }
  place(anchor, tip)
}

function hide() {
  if (!current) return
  const { tip } = current
  current = null

  if (typeof tip.hidePopover === 'function') {
    try {
      tip.hidePopover()
    } catch (_error) {
      // Already closed or removed from the page.
    }
  }
  tip.classList.add('hidden')
}

function place(anchor, tip) {
  const trigger = anchor.firstElementChild || anchor
  const target = trigger.getBoundingClientRect()
  const box = tip.getBoundingClientRect()
  const viewportWidth = document.documentElement.clientWidth
  const viewportHeight = document.documentElement.clientHeight

  const centre = target.left + target.width / 2
  const left = Math.min(
    Math.max(EDGE, centre - box.width / 2),
    Math.max(EDGE, viewportWidth - box.width - EDGE)
  )

  const roomAbove = target.top - box.height - GAP >= EDGE
  const roomBelow = target.bottom + box.height + GAP <= viewportHeight - EDGE
  const above = tip.dataset.position === 'top' ? roomAbove || !roomBelow : !roomBelow && roomAbove

  tip.style.left = `${left}px`
  tip.style.top = `${above ? target.top - box.height - GAP : target.bottom + GAP}px`
  tip.dataset.side = above ? 'top' : 'bottom'

  const arrow = tip.querySelector('[data-tooltip-arrow]')
  if (arrow) {
    const arrowLeft = Math.min(Math.max(ARROW_INSET, centre - left), box.width - ARROW_INSET)
    arrow.style.left = `${arrowLeft}px`
  }
}

// LiveView patches replace attributes with the server's markup, which would hide an open tip or
// drop its position. Carry them over for the tip that is open.
export function keepOpenTooltip(from, to) {
  if (!current) return
  const isTip = from === current.tip
  const isArrow = from.parentElement === current.tip && from.hasAttribute('data-tooltip-arrow')
  if (!isTip && !isArrow) return

  to.style.cssText = from.style.cssText
  if (isTip) {
    to.classList.remove('hidden')
    to.dataset.side = from.dataset.side
  }
}

function anchorFrom(target) {
  return target instanceof Element ? target.closest('[data-tooltip-anchor]') : null
}

function isControlIn(anchor, target) {
  const control = target.closest(CONTROLS)
  return !!control && anchor.contains(control)
}

export function installTooltips(root = document) {
  root.addEventListener('pointerover', (event) => {
    if (event.pointerType !== 'mouse') return
    const anchor = anchorFrom(event.target)
    if (anchor && anchor !== suppressed) show(anchor)
  })

  root.addEventListener('pointerout', (event) => {
    if (event.pointerType !== 'mouse') return
    if (suppressed && !suppressed.contains(event.relatedTarget)) suppressed = null
    if (current && !current.anchor.contains(event.relatedTarget)) hide()
  })

  root.addEventListener('focusin', (event) => {
    const anchor = anchorFrom(event.target)
    if (anchor && event.target.matches(':focus-visible')) show(anchor)
  })

  root.addEventListener('focusout', (event) => {
    if (current && !current.anchor.contains(event.relatedTarget)) hide()
  })

  // Clicking a control means the label has done its job, and it would cover menus the control opens.
  root.addEventListener(
    'pointerdown',
    (event) => {
      const anchor = anchorFrom(event.target)
      const wasOpen = !!anchor && current?.anchor === anchor
      hide()

      if (event.pointerType !== 'mouse' && anchor && !isControlIn(anchor, event.target)) {
        suppressed = null
        if (!wasOpen) show(anchor)
      } else {
        suppressed = anchor
      }
    },
    true
  )
  root.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hide()
  })

  window.addEventListener('scroll', hide, true)
  window.addEventListener('resize', hide)
  window.addEventListener('phx:page-loading-start', hide)
}
