# Migration wiki upload checklist

Published October 14, 2026 at wiki commit `e7517c981e2d2a5ca2b3cdac236f968e4581c73d`. Post-merge hygiene (October 15, 2026): removed the stale PR #86 “upcoming update” callout from the live wiki and local `docs/legacy-pinchflat-migration.md` after #86 merged to `master`. Migration summary posted on issue #82 (2026-10-14). Local draft retained in `docs/migration-issue-comment-draft.md` for edits only.

## Pages and links

| Local source | Wiki title | Wiki slug |
| --- | --- | --- |
| `docs/legacy-pinchflat-migration.md` | Migrating from Pinchflat | `Migrating-from-Pinchflat` |
| `docs/backing-up-config-before-migration.md` | Backing up config before migration | `Backing-up-config-before-migration` |

- [ ] Review `docs/migration-wiki-preview.html` locally, including images and both pages. The Markdown files remain the editable source.
- [x] Confirm the release being documented includes the migration welcome/review work from PR #86 (merged 2026-10-14).
- [x] Create/update exactly the two wiki pages using the titles and slugs above.
- [x] In the pasted main page, replace `(backing-up-config-before-migration.md)` with `(https://github.com/TheBadFella/pinchflat-ngx/wiki/Backing-up-config-before-migration)`.
- [x] In the pasted backup page, replace `(legacy-pinchflat-migration.md)` with `(https://github.com/TheBadFella/pinchflat-ngx/wiki/Migrating-from-Pinchflat)`.
- [x] On the existing **Installation** and **Upgrading and rollback** wiki pages, add links to these two pages. The main migration page intentionally has no Related guides section. Do not duplicate backup commands.

## Image upload

Only the main page has images:

- `02-migration-welcome.jpg`
- `03-library-summary.jpg`
- `04-sources-ready.png`
- `05-welcome-mobile.jpg`

- [x] Upload these four original files to the wiki's `assets/migration/` directory using its Git checkout, or use GitHub's attachment upload and retain each returned image URL.
- [x] For wiki Git assets, replace local Markdown image targets `assets/migration/NAME.ext` with `https://raw.githubusercontent.com/wiki/TheBadFella/Pinchflat-NGX/assets/migration/NAME.ext`. For attachments, use the actual returned URLs. Do not use local filesystem paths or assume uncommitted files exist on repository `master`.
- [ ] Preserve alt text and the captions explaining test data, missing files and post-confirmation policy behavior and the separate clean Sources example. Verify the mobile `<details>` expands and its image loads.
- [x] Do not upload the removed SVG placeholders. Compose remains YAML-only. Do not add images to the backup page.

## Read back after manual publication

- [ ] Open both wiki URLs while signed out; check image requests, mobile width and all cross-links.
- [ ] Main page still answers keep/change/add, contains three switch steps, and has no backup commands.
- [ ] Backup commands archive and restore config only; current config is retained during rollback. There are no media backup commands.
- [ ] Confirm schema upgrades precede review, file verification is readability/size only, and confirmation resumes configured policies while preserving prior pauses. Do not describe a missing-file warning as data loss caused by migration.
- [ ] PostgreSQL transfer and adopting untracked files remain separate operations. Nothing announces SQLite retirement.

Screenshot provenance and slot mapping: `docs/assets/migration/README.md`.

## Local verification — October 14, 2026

- Both Markdown pages rendered together in `migration-wiki-preview.html`; all four local images loaded. Desktop and 390px mobile had no page overflow; page links resolve and the mobile disclosure opens.
- Image bytes match their source captures. Local Markdown targets exist; no SVG placeholder references remain. Backup page has no images or media backup commands; main page has no backup commands.
- The documented Bash restore block passed four isolated Docker Compose fixture checks: nested database, older root database, corrupt archive rejection, and archive-without-database rejection. Success cases preserved original config plus WAL/SHM bytes and retained the replaced config. Rejection cases left live fixture config unchanged. The first harness attempt failed at Compose variable interpolation before execution; the corrected runner passed the script as an argument without altering the documented commands.
- Both PowerShell blocks passed parser checks only; Windows restore execution was not performed.
- Documentation and assets only; no application tests, application edits, commits, pushes or wiki writes. The owned validation container was removed and teardown preserved volumes.

## Local review follow-up

Removed the main page's Related guides section. Replaced the completed-dashboard capture containing deliberately failed fixture rows with the unchanged clean `sources-table.png` capture from the same migration-guide worktree. This is a separate example library, not evidence that the earlier fixture failures were repaired. No error rows were hidden or edited out of an image.
