# Release 2026.6.6

> [!IMPORTANT]
> **Personal Fork Disclaimer:** This fork is maintained for personal use and to address ongoing maintenance needs. It was created following a period of over six months without updates to the original upstream repository.

---

This release delivers the source directory move confirmation flow, dependency maintenance updates, and release preparation for version `2026.6.6`.

---

## Changes

### Source Directory Safety

- Add a confirmation step before moving a source directory when a source output path changes
- Preserve existing source update behavior when the directory path is unchanged
- Move directory contents and update media file paths only after the confirmation flow is accepted
- Log source directory move failures explicitly while keeping the updated source record available

### Dependency And Workflow Maintenance

- Update `phoenix` from 1.8.5 to 1.8.7
- Update `ecto` from 3.13.5 to 3.13.6
- Update `ecto_sqlite3` from 0.22.0 to 0.23.0
- Update `open_api_spex` from 3.22.2 to 3.22.3
- Update `jason` from 1.4.4 to 1.4.5
- Update pinned GitHub Actions for checkout, Docker login, Docker metadata, and Docker Buildx setup

### Release Prep

- Bump the application version from `2026.3.28` to `2026.6.6`
- Add release notes for changes after `c54ae484a1e78bec8ddb48c11b42c76b3a09d80f`
- Clean up source form modal button indentation
- Refine successful source directory move handling to use an explicit success branch

---

## Verification

- Release prepared from merged `master` at commit `8d8a10b` after PR #53 was merged
- Release notes cover changes after commit `c54ae484a1e78bec8ddb48c11b42c76b3a09d80f`
- Docker `mix check` passed with `1170 tests, 0 failures`
- GitHub PR merged: #53

---
