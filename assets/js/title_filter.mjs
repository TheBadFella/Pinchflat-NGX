// Title filter builder for the source form.
//
// Turns three lists of plain words (any / all / none), each with its own "whole words" and
// "match case" switches, into the regex that the title filter field stores, and reads that
// regex back into the lists when a source is edited. Regexes it cannot read (anything
// hand-written) are left alone and flagged as `custom`.
//
// The regex has to work in both databases: SQLite (sqlean regexp_like, PCRE-style) and
// Postgres (`~`, ARE syntax):
// - Postgres reads `\b` as a backspace, not a word boundary, so word edges are written as
//   lookarounds that both understand.
// - Postgres only accepts a case option at the very start of the regex, as `(?i)`. When every
//   list ignores case the regex starts with `(?i)`. When the lists differ, the lists that ignore
//   case spell each letter as a pair instead, the letter as typed first (`[Ss]`, `[tT]`), so
//   the lists read back exactly as they were entered. Only A-Z are spelled out this way.
const WORD_START = '(?<!\\w)'
const WORD_END = '(?!\\w)'
const LISTS = ['any', 'all', 'none']

export const defaultOptions = () => ({
  any: { whole: true, matchCase: false },
  all: { whole: true, matchCase: false },
  none: { whole: true, matchCase: false }
})

export const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// 'a, "b, c", d' -> ['a', 'b, c', 'd']  (commas inside double quotes are kept)
export const splitTerms = (text) => {
  const out = []
  let current = ''
  let quoted = false

  for (const char of text) {
    if (char === '"') {
      quoted = !quoted
    } else if (char === ',' && !quoted) {
      out.push(current)
      current = ''
    } else {
      current += char
    }
  }
  out.push(current)

  return out.map((term) => term.trim()).filter((term) => term.replace(/\*/g, '').length > 0)
}

const spellCaseless = (text) =>
  text.replace(
    /[A-Za-z]/g,
    (char) =>
      '[' + char + (char === char.toLowerCase() ? char.toUpperCase() : char.toLowerCase()) + ']'
  )

// One search term -> regex. "*" is a wildcard; whole-word marks the word edges of the term.
const termToRegex = (raw, whole, caselessLetters = false) => {
  let body = raw.split('*').map(escapeRegex).join('.*')
  if (caselessLetters) body = spellCaseless(body)
  const isWordChar = (char) => whole && /\w/.test(char)
  return (
    (isWordChar(raw[0]) ? WORD_START : '') +
    body +
    (isWordChar(raw[raw.length - 1]) ? WORD_END : '')
  )
}

// state: { any, all, none, options: { any: { whole, matchCase }, all: ..., none: ... } }
//   all  -> every one must appear     (?=.*A)(?=.*B)
//   any  -> at least one must appear  (?=.*(?:A|B))
//   none -> none may appear           (?!.*(?:A|B))
export const buildRegex = (state) => {
  const { any, all, none, options } = state
  const used = LISTS.filter((key) => state[key].length > 0)
  if (used.length === 0) return ''

  const allCaseless = used.every((key) => !options[key].matchCase)
  const toRegex = (key) => (term) =>
    termToRegex(term, options[key].whole, !allCaseless && !options[key].matchCase)
  const parts = []

  all.forEach((term) => parts.push('(?=.*' + toRegex('all')(term) + ')'))
  if (any.length) parts.push('(?=.*(?:' + any.map(toRegex('any')).join('|') + '))')
  if (none.length) parts.push('(?!.*(?:' + none.map(toRegex('none')).join('|') + '))')

  return (allCaseless ? '(?i)' : '') + '^' + parts.join('') + '.*$'
}

// Reads back a regex written by buildRegex. Also reads the older single-option form and `\b`
// word edges (SQLite only), which are rewritten in the current form on the next change.
// Returns null for any other regex.
export const parseRegex = (regex) => {
  let rest = (regex || '').trim()
  if (!rest) return { any: [], all: [], none: [], options: defaultOptions() }

  const caselessPrefix = rest.startsWith('(?i)')
  if (caselessPrefix) rest = rest.slice(4)
  if (rest[0] !== '^' || !rest.endsWith('.*$')) return null
  rest = rest.slice(1, -3)

  const result = { any: [], all: [], none: [], options: defaultOptions() }
  const stats = Object.fromEntries(
    LISTS.map((key) => [key, { edges: 0, bounded: 0, plain: 0, spelled: 0 }])
  )
  let i = 0
  let anyGroups = 0

  // Reads one term, counting its word edges and how its letters are written
  const readTerm = (stat) => {
    let term = ''
    while (i < rest.length && rest[i] !== '|' && rest[i] !== ')') {
      const char = rest[i]
      const edge = [WORD_START, WORD_END].find((token) => rest.startsWith(token, i))
      const spelled = rest.slice(i, i + 4).match(/^\[([A-Za-z])([A-Za-z])\]$/)
      if (edge) {
        stat.bounded++
        i += edge.length
      } else if (
        spelled &&
        spelled[1] !== spelled[2] &&
        spelled[1].toLowerCase() === spelled[2].toLowerCase()
      ) {
        stat.spelled++
        term += spelled[1] // the letter as it was typed comes first
        i += 4
      } else if (char === '\\') {
        const next = rest[i + 1]
        if (next === undefined) return null
        if (next === 'b') {
          stat.bounded++
          i += 2
          continue
        }
        if (/[a-zA-Z0-9]/.test(next)) return null // \d, \w ... not ours
        term += next
        i += 2
      } else if (char === '.' && rest[i + 1] === '*') {
        term += '*'
        i += 2
      } else if ('([{}]+?^$.'.includes(char)) {
        return null
      } else {
        if (/[A-Za-z]/.test(char)) stat.plain++
        term += char
        i++
      }
    }
    return term
  }

  while (i < rest.length) {
    let negated
    if (rest.startsWith('(?=.*', i)) negated = false
    else if (rest.startsWith('(?!.*', i)) negated = true
    else return null
    i += 5

    const grouped = rest.startsWith('(?:', i)
    if (grouped) i += 3
    const key = negated ? 'none' : grouped ? 'any' : 'all'
    if (key === 'any' && ++anyGroups > 1) return null
    const stat = stats[key]

    for (;;) {
      const term = readTerm(stat)
      if (!term) return null
      result[key].push(term)
      if (/\w/.test(term[0])) stat.edges++
      if (/\w/.test(term[term.length - 1])) stat.edges++
      if (grouped && rest[i] === '|') {
        i++
        continue
      }
      break
    }

    if (grouped) {
      if (rest[i] !== ')') return null
      i++
    }
    if (rest[i] !== ')') return null
    i++
  }

  for (const key of LISTS) {
    const stat = stats[key]
    // Spelled-out and plain letters in one list never come from the builder
    if (stat.spelled > 0 && stat.plain > 0) return null
    if (caselessPrefix && stat.spelled > 0) return null

    result.options[key].whole = stat.edges === 0 ? true : stat.bounded > 0
    result.options[key].matchCase = caselessPrefix ? false : stat.spelled === 0 && stat.plain > 0
  }
  return result
}

// Contradictions between the word lists: a NONE word that is always found in a title that
// has one of the ALL or ANY words, under each list's case and whole-word settings. With
// "Whole words only" on for NONE, "asd" is not found in "asdf", so that pair is not a
// conflict. A pair only counts when it clashes for every title the word could appear in:
// a "*" is tried as nothing, a space and a letter; a word matched without whole words is
// tried with letters around it; a word that ignores case is tried in upper and lower case
// when NONE matches capital letters.
const WILDCARD_FILLS = ['', ' ', 'x']

const quote = (term) => '\u201c' + term + '\u201d'

const titleVariants = (term, options, noneOptions) => {
  const filled = WILDCARD_FILLS.map((fill) => term.split('*').join(fill))
  const cased =
    !options.matchCase && noneOptions.matchCase
      ? filled.flatMap((text) => [text, text.toLowerCase(), text.toUpperCase()])
      : filled
  return options.whole ? cased : cased.flatMap((text) => [text, 'x' + text + 'x'])
}

export const findConflicts = ({ any, all, none, options }) => {
  const conflicts = []

  for (const blocked of none) {
    const matcher = new RegExp(
      termToRegex(blocked, options.none.whole),
      options.none.matchCase ? 'u' : 'iu'
    )
    const alwaysFound = (key) => (term) =>
      titleVariants(term, options[key], options.none).every((text) => matcher.test(text))

    for (const term of all.filter(alwaysFound('all'))) {
      conflicts.push({
        list: 'all',
        term,
        blocked,
        message:
          quote(term) +
          ' has to be in the title, but NONE skips every title with ' +
          quote(blocked) +
          ', so nothing can be downloaded.'
      })
    }
    for (const term of any.filter(alwaysFound('any'))) {
      conflicts.push({
        list: 'any',
        term,
        blocked,
        message:
          quote(term) +
          ' is one of the ANY words, but NONE skips every title with ' +
          quote(blocked) +
          ', so that word can never lead to a download.'
      })
    }
  }

  return conflicts
}

// Alpine state for the builder. Merge it into the component that owns `regex`, the
// value of the real title filter field (bound with x-model there). Builder edits write
// `regex`; edits to the field are read back into the lists.
export const titleFilterBuilder = (initialRegex = '') => ({
  regex: initialRegex,
  terms: { any: [], all: [], none: [] },
  options: defaultOptions(),
  custom: false,
  builtRegex: null,

  // Set when a save was stopped because of conflicts, so the page can point at them
  conflictsBlockedSave: false,

  init() {
    this.readRegex()
    this.$watch('regex', () => {
      // Our own writes come back through this watcher; only hand edits are read back
      if (this.regex !== this.builtRegex) this.readRegex()
    })

    // Saving the source with a contradictory filter is stopped until the conflict is fixed
    this.$el?.closest('form')?.addEventListener(
      'submit',
      (event) => {
        if (!this.preventSaveOnConflict()) return
        event.preventDefault()
        event.stopImmediatePropagation()
      },
      true
    )
  },

  conflicts() {
    return this.custom ? [] : findConflicts(this.state())
  },

  // Returns true when there are conflicts, after opening the group and showing them
  preventSaveOnConflict() {
    if (this.conflicts().length === 0) return false

    this.conflictsBlockedSave = true
    const group = this.$el?.closest('details')
    if (group) group.open = true
    this.$nextTick?.(() => this.$refs?.conflicts?.scrollIntoView({ block: 'center' }))
    return true
  },

  readRegex() {
    const parsed = parseRegex(this.regex)
    if (parsed) {
      this.terms = { any: parsed.any, all: parsed.all, none: parsed.none }
      this.options = parsed.options
      this.custom = false
    } else {
      this.terms = { any: [], all: [], none: [] }
      this.options = defaultOptions()
      this.custom = this.regex.trim() !== ''
    }
    this.builtRegex = null
  },

  state() {
    return { ...this.terms, options: this.options }
  },

  hasTerms() {
    return Object.values(this.terms).some((list) => list.length > 0)
  },

  writeRegex() {
    // Do not wipe a hand-written regex until the builder has something to put in its place
    if (this.custom && !this.hasTerms()) return

    this.builtRegex = buildRegex(this.state())
    this.regex = this.builtRegex
    this.custom = false
    if (this.conflicts().length === 0) this.conflictsBlockedSave = false
  },

  conflictHint() {
    return this.conflictsBlockedSave
      ? 'Saving was stopped. Remove or change one of the highlighted words, then save again.'
      : 'The source cannot be saved until this is fixed.'
  },

  isConflicting(key, term) {
    return this.conflicts().some(
      (conflict) =>
        (conflict.list === key && conflict.term === term) ||
        (key === 'none' && conflict.blocked === term)
    )
  },

  addTerms(key, text) {
    let changed = false
    for (const term of splitTerms(text.replace(/\r?\n/g, ','))) {
      if (!this.terms[key].some((existing) => existing.toLowerCase() === term.toLowerCase())) {
        this.terms[key].push(term)
        changed = true
      }
    }
    if (changed) this.writeRegex()
  },

  removeTerm(key, index) {
    this.terms[key].splice(index, 1)
    this.writeRegex()
  },

  // Enter or comma adds the word; Backspace on an empty box removes the last one.
  // A comma inside an open "quote" is part of the phrase.
  termKeydown(key, event) {
    const input = event.target
    const openQuote = (input.value.match(/"/g) || []).length % 2 === 1

    if (event.key === 'Enter' || (event.key === ',' && !openQuote)) {
      event.preventDefault() // never submit the form
      this.addTerms(key, input.value)
      input.value = ''
    } else if (event.key === 'Backspace' && !input.value && this.terms[key].length) {
      this.removeTerm(key, this.terms[key].length - 1)
    }
  },

  termBlur(key, event) {
    this.addTerms(key, event.target.value)
    event.target.value = ''
  },

  termPaste(key, event) {
    event.preventDefault()
    this.addTerms(key, (event.clipboardData || window.clipboardData).getData('text'))
  },

  clearFilter() {
    this.conflictsBlockedSave = false
    this.terms = { any: [], all: [], none: [] }
    this.options = defaultOptions()
    this.custom = false
    this.builtRegex = ''
    this.regex = ''
  }
})
