# Major Asset Upgrades Checklist

Branch: `chore/major-asset-upgrades`

## Goals

- [x] Audit current esbuild and Tailwind setup
- [x] Upgrade Phoenix esbuild wrapper and binary target
- [x] Upgrade Phoenix Tailwind wrapper and binary target
- [x] Migrate the main stylesheet entrypoint for Tailwind CSS v4
- [x] Keep legacy `tailwind.config.js` compatibility working via `@config`
- [x] Make Tailwind forms plugin explicit instead of relying on implicit availability
- [x] Review Tailwind v4 breaking changes that may affect this app
- [x] Upgrade Docker asset/runtime setup to Node 24
- [x] Align `selfhosted.Dockerfile` base image versions with current supported pins
- [ ] Validate build/test flow after the upgrade

## Notes

- Tailwind CSS v4 removes the old `@import "tailwindcss/base|components|utilities"` entrypoint style in favor of `@import "tailwindcss"`.
- Tailwind CSS v4 no longer auto-detects `tailwind.config.js`; if we keep the JS config for now, it must be loaded with `@config`.
- The app currently uses `@tailwindcss/forms`, but it is not declared in `assets/package.json`. This should be made explicit as part of the upgrade.
- Tailwind CSS v4 has browser baseline changes and some utility behavior changes. A manual UI pass is required even if the build succeeds.
- The Dockerfiles currently manage the Node runtime for asset compilation independently of `mix.exs`, so the major asset upgrade needs a matching Docker update.
- `docker compose run --rm phx mix test` passed after the upgrade on March 27, 2026.
- `docker compose run --rm phx mix check` still fails, but due to pre-existing Credo issues outside this asset upgrade:
  - `lib/pinchflat/metadata/source_metadata_storage_worker.ex:52` (`with` with a single `<-`)
  - `test/pinchflat_web/controllers/sources/source_controller_api_test.exs:20` (`length/1`)
  - `test/pinchflat_web/controllers/api/task_controller_test.exs:90` (`length/1`)
  - repo-wide existing line-ending consistency findings
