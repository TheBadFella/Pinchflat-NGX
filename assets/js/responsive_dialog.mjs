export const responsiveDialog = {
  mounted() {
    this.openDialog = (event) => {
      this.trigger = document.activeElement
      if (!this.el.open) this.el.showModal()
      document.body.classList.add('overflow-hidden')
      if (event.detail?.custom) {
        this.el.querySelector('details').open = true
        this.el.querySelector('input[name="from"]').focus()
      }
    }
    this.closeDialog = () => this.el.close()
    this.onClose = () => {
      if (this.el.open) return
      document.body.classList.remove('overflow-hidden')
      this.trigger?.focus()
    }
    this.onBackdrop = (event) => {
      if (event.target !== this.el) return
      const rect = this.el.getBoundingClientRect()
      if (
        event.clientX < rect.left ||
        event.clientX > rect.right ||
        event.clientY < rect.top ||
        event.clientY > rect.bottom
      )
        this.el.close()
    }
    this.onResize = () => {
      if (window.innerWidth >= 640 && this.el.open) this.el.close()
    }
    this.el.addEventListener('open-dialog', this.openDialog)
    this.el.addEventListener('close-dialog', this.closeDialog)
    this.el.addEventListener('close', this.onClose)
    this.el.addEventListener('click', this.onBackdrop)
    window.addEventListener('resize', this.onResize)
  },
  beforeUpdate() {
    this.wasOpen = this.el.open
    this.focused = document.activeElement
    this.scrollTop = this.el.scrollTop
    this.datesOpen = this.el.querySelector('details')?.open
  },
  updated() {
    if (this.wasOpen && !this.el.open) {
      this.el.showModal()
      if (this.el.contains(this.focused)) this.focused.focus({ preventScroll: true })
      this.el.scrollTop = this.scrollTop
    }
    if (this.datesOpen) this.el.querySelector('details').open = true
  },
  destroyed() {
    window.removeEventListener('resize', this.onResize)
    this.el.removeEventListener('open-dialog', this.openDialog)
    this.el.removeEventListener('close-dialog', this.closeDialog)
    this.el.removeEventListener('close', this.onClose)
    this.el.removeEventListener('click', this.onBackdrop)
    if (this.el.open) document.body.classList.remove('overflow-hidden')
  }
}
