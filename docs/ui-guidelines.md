# UI Guidelines

## Goal

Keep the web UI aligned to Material Design 3 foundations and prevent theme drift from hardcoded colors or one-off component styling.

## Rules

- Use Material Design 3 theme tokens from [app.css](/D:/Git/PinchYT/assets/css/app.css) for color decisions.
- Prefer shared semantic classes such as status, destructive, badge, surface, and active-state classes over page-local class combinations.
- Do not introduce raw palette classes like `text-red-*`, `bg-red-*`, `border-green-*`, or similar in `lib/pinchflat_web`.
- Do not introduce `zinc-*` classes in `lib/pinchflat_web`.
- If a new visual state is needed, add or extend a semantic class in `assets/css/app.css` instead of styling a single screen inline.
- Keep navigation, form focus, alerts, and destructive actions visually distinct, even when they share the same token family.

## Current Decisions

- Flash alerts remain a static alert pattern and do not use the perimeter/field-shell interaction treatment.
- Sidebar active state stays calmer than active form fields.
- Active form fields keep the stronger perimeter emphasis because they represent editing/focus state.

## Guardrail

Run this check before merging UI work:

```bash
yarn run ui:check-theme
```

That script fails if raw palette classes or `zinc-*` classes are introduced into `lib/pinchflat_web`.
