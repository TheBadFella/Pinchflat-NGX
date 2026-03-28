# Theme Upgrade

Track the AMOLED black Material 3 UI migration here.

## Goals

- Move the UI from the current custom dark dashboard theme to a tokenized Material 3-inspired theme.
- Use an AMOLED-black base without making every elevated surface pure black.
- Refactor shared components first, then page-level templates.
- Keep the app usable throughout the migration.

## Status

Current phase: Theme foundation

Current status: Complete

## Theme Direction

- App background: true black or near-true black
- Elevated surfaces: near-black layered containers
- Accent system: Material 3-style semantic roles
- Shape language: larger radii than the current dashboard styling
- Borders and focus states: subtle but visible on black
- Scope: existing dark-first UI first, optional light theme later

## Workstreams

### 1. Audit

- [x] Inventory current color tokens in the legacy Tailwind config and migrate them to CSS-native Tailwind v4 theme tokens
- [x] Inventory hard-coded color and surface classes in shared components
- [x] Inventory hard-coded color and surface classes in page templates
- [x] Identify components that should become theme primitives

### 2. Theme Foundation

- [x] Define Material 3-inspired semantic color roles
- [x] Define AMOLED surface scale
- [x] Define text, outline, focus, success, warning, and error roles
- [x] Define radius and elevation conventions
- [x] Update base CSS in `assets/css/app.css`
- [x] Update Tailwind theme tokens in `assets/css/app.css` using CSS-native Tailwind v4 `@theme`

### 3. Shared Components

- [x] Refactor `PinchflatWeb.CoreComponents`
- [x] Refactor `ButtonComponents`
- [x] Refactor `TableComponents`
- [x] Refactor `TabComponents`
- [x] Refactor `TextComponents`
- [x] Refactor layout partials for header and sidebar

### 4. Screens

- [x] Home dashboard
- [x] Sources index/show/forms
- [x] Media profiles index/show/forms
- [x] Media item pages
- [x] Settings pages
- [x] Search pages
- [x] Error pages
- [x] Onboarding pages

### 5. QA

- [x] Verify contrast on primary screens
- [x] Verify hover, active, disabled, and focus states
- [ ] Verify mobile layouts
- [x] Verify LiveView flash, modal, and form states
- [x] Run formatting
- [~] Run Docker test/check commands relevant to UI changes

## Decisions

### Open

- [ ] Whether to support both current dark theme and new theme during migration
- [ ] Whether to add a user-facing theme toggle now or later

### Decided

- [x] Start with the existing dark-first UI instead of introducing light mode at the same time
- [x] Track the migration in this document
- [x] Use the provided Material palette for primary, secondary, and tertiary roles
- [x] Use Roboto throughout the app
- [x] Keep only the new theme during migration unless requirements change
- [x] Remove the legacy theme token layer instead of keeping compatibility aliases

## Change Log

### 2026-03-23

- Created this tracker
- Confirmed the app is already dark-first via root layout
- Confirmed current styling is partly tokenized but still contains many hard-coded surface/color classes
- Completed initial audit of theme tokens and styling hotspots
- Added semantic AMOLED Material-style theme tokens in Tailwind and base CSS
- Switched the root app shell to the new semantic theme classes
- Migrated button, table, and tab shared components onto the new semantic theme tokens
- Migrated core form, modal, flash, text, navigation, and layout shared components onto the new semantic theme tokens
- Migrated the Home, Sources, Media Profiles, Media Item, and Onboarding screens plus their nested LiveView tables/panels to the new semantic theme tokens
- Fixed the remaining shared-component compile warning in `layouts.ex`
- Ran Docker formatting, compile, and full `mix check` validation
- Removed the legacy dashboard palette, Satoshi font import, and final old-theme runtime references from `assets/` and `lib/`
- Re-ran Docker formatting and compile after the legacy theme cleanup
- Switched single-select form controls from native browser dropdowns to a custom HEEx/Alpine component for consistent dark styling
- Added shared animated perimeter borders for focused form fields and active select triggers
- Increased default form-control border weight and strengthened dropdown menu/option contrast for readability

## Audit Findings

### Current theme entry points

- `assets/css/app.css` defines the current semantic Tailwind v4 theme layer using `@theme`
- `assets/css/app.css` also declares Tailwind source detection with `@source`
- `lib/pinchflat_web/components/layouts/root.html.heex` keeps the app in the dark theme shell

### High-frequency hard-coded styling patterns

- `text-white`: 93 matches
- `dark:text-white`: 45 matches
- `text-black`: 34 matches
- `bg-boxdark`: 30 matches
- `rounded-sm`: 30 matches
- `border-strokedark`: 30 matches
- `bg-white`: 23 matches
- `shadow-default`: 19 matches
- `bg-primary`: 18 matches
- `bg-meta-4`: 13 matches
- `bg-form-input`: 5 matches

### Shared components to convert first

- `PinchflatWeb.CoreComponents`
- `PinchflatWeb.CustomComponents.ButtonComponents`
- `PinchflatWeb.CustomComponents.TableComponents`
- `PinchflatWeb.CustomComponents.TabComponents`
- `PinchflatWeb.CustomComponents.TextComponents`
- Layout partials for header, sidebar, and modals

### Page areas with old theme coupling

- Home dashboard cards and history container
- Sources index/show/forms
- Media profiles index/show/forms
- Media item pages
- Error pages

### Migration approach confirmed

- Replace current palette tokens with Material 3-style semantic roles
- Refactor shared components before broad page-template cleanup
- Treat `rounded-sm`, `shadow-default`, and related surface styling as part of the migration, not just colors

## Foundation Implemented

- Semantic colors added for background, layered surfaces, on-surface text, outlines, primary, secondary, error, success, warning, and scrim
- AMOLED surface scale added using CSS variables in `assets/css/app.css`
- Material-style radii added in CSS-native Tailwind v4 theme tokens
- New surface and button utility classes added for incremental migration
- Global focus-visible treatment added for keyboard navigation
- Root layout updated to consume the new app-shell classes

## Current Screen Status

- Section 4 is complete
- Home, Sources, Media Profiles, Media Items, Settings, Search, Error, and Onboarding screens are migrated
- Legacy runtime theme references have been removed from the app code
- The legacy `assets/tailwind.config.js` bridge has been removed in favor of CSS-native Tailwind v4 theme configuration

## QA Notes

- `docker compose run --rm phx mix format` completed
- `docker compose run --rm phx mix compile` completed
- `docker compose run --rm phx mix check` ran through compile, sobelow, formatter, prettier, and tests successfully
- `mix check` still exits non-zero because `credo` reports existing repository issues unrelated to this theme pass:
  - two existing `length/1` warnings in tests
  - many existing line-ending consistency issues across unrelated files
- Preview server is available via `docker-compose.preview.yml` on `http://localhost:4200`

## Notes

- Prefer centralizing theme roles before making broad template edits.
- Shared component refactors should land before page-by-page cleanup.
- Avoid mixing old semantic tokens and new semantic tokens longer than necessary.
