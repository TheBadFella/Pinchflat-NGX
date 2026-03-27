# UI Consistency Checklist

## Goal

Bring the UI onto a single shared theme system so colors, borders, active states, destructive actions, and status messaging behave consistently across home, sources, jobs, settings, and forms.

## Checklist

- [x] Audit the current UI for theme inconsistencies
- [x] Document the findings in `docs/`
- [x] Replace raw Tailwind status colors with semantic theme classes
- [x] Replace ad hoc destructive action styles with shared destructive button/link styles
- [x] Normalize error panels, error icons, and error text blocks to shared theme semantics
- [x] Normalize job/status summary cards to shared status-card semantics
- [x] Normalize system health warning/success/error indicators to shared semantics
- [x] Remove or quarantine legacy `zinc-*` visual patterns in shared core components
- [x] Review source and home screens for any remaining raw palette classes
- [x] Review settings, media profiles, and onboarding screens for any remaining raw palette classes
- [x] Run format + focused tests after each cleanup pass
- [x] Run a final full UI consistency pass before closing the checklist

## Current Findings

### Theme token bypasses

- [x] `Job Queue` stat cards use raw palette colors instead of theme status classes
- [x] `Job Queue` cancel actions use raw red text styles
- [x] `Job Queue` error detail body uses raw red text styling
- [x] `Active Tasks` cancel actions use raw red border/text styles
- [x] `System Health` warning/success states use raw yellow/green text styles
- [x] source/home media tables use raw red error icon/panel/stop-button styles

### Shared component drift

- [x] decide whether `flash` left-border alerts should remain the canonical alert style or be aligned to the perimeter/field-shell system
- [x] decide whether sidebar active animation and active-field animation should converge further or remain intentionally separate
- [x] remove or deprecate legacy `old_header` / `old_table` zinc-based styling from shared components

### Recorded decisions

- [x] `flash` alerts remain a separate static alert pattern rather than adopting the perimeter/field-shell interaction language
- [x] sidebar active state and active field state stay in the same Material 3 family, but with intentionally different intensity
- [x] active fields keep the stronger perimeter emphasis for editing/focus state
- [x] sidebar active state remains calmer and lower-motion so navigation does not compete with form interaction

## Final Pass Result

- [x] repo-wide search confirms no remaining raw `red/green/blue/yellow/orange` palette classes in `lib/pinchflat_web`
- [x] repo-wide search confirms no remaining `zinc-*` classes in `lib/pinchflat_web`
- [x] remaining open items are design-direction decisions, not token drift bugs

## Cleanup Notes

- Start with shared semantic classes in `assets/css/app.css`
- Prefer theme classes over one-off `text-red-*`, `bg-red-*`, `border-green-*`, etc.
- Keep motion subtle and respect `prefers-reduced-motion`
- Avoid introducing new raw palette classes unless a true new design token is required
