# Stable release runbook

This runbook describes the automated stable release flow for Pinchflat-ngx. It
is maintainer documentation; user-facing upgrade instructions belong on the
[wiki](https://github.com/TheBadFella/Pinchflat-NGX/wiki).

## What the automation owns

Two thin workflows and one stdlib-only Python engine implement the release
flow:

| Component                                 | Purpose                                                                                                                                             |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/release_candidate.yml` | Prepares or refreshes one draft release-candidate PR from `dev` into `master`.                                                                      |
| `.github/workflows/release_publish.yml`   | Validates the merge commit, tags it, creates the GitHub Release, starts the stable publisher, verifies manifests, and syncs `master` back to `dev`. |
| `tooling/release_automation/`             | Version policy, PR-body markers, metadata validation, git branch construction, GitHub API calls, and publisher routing.                             |
| `test/tooling/`                           | Offline acceptance suite with a stateful fake GitHub API and real temporary git repositories.                                                       |

The automation never rewrites a release tag, never creates a release from an
unrelated PR, and never treats release-note text as shell code.

## Version policy

Versions use `YEAR.MONTH.PATCH` in the `America/Regina` timezone:

- Same year and month as the latest published stable release: increment patch
  (`2026.11.0` -> `2026.11.1`).
- Later month or year: reset patch to zero (`2026.12.0`).
- A clock earlier than the latest release month stops preparation.
- An explicit override is accepted only when it is canonical and strictly newer
  than the latest published stable release.
- No published stable release requires an explicit `bootstrap_version`.
- Repeated preparation with the same source, baseline, and version is a no-op.
- A tag that already points at a different commit stops preparation.

Released tags retain the repository's `YEAR.MONTH.PATCH` spelling, without a `v`
prefix. Historical tags with either spelling are recognized as baselines.

## Activation prerequisites

### Default-off activation gate

The workflows have separate default-off switches:

- `RELEASE_CANDIDATE_ENABLED=true` enables candidate preparation on `dev` pushes.
- `RELEASE_PUBLISH_ENABLED=true` enables stable publication on `master` pushes.

Leave both unset while reviewing the implementation. After a disposable-repository
trial, enable candidate preparation first. Enable stable publication only after
reviewing a generated candidate and verifying credentials, branch rules and CI.
Deleting either variable or setting it to `false` disables its automatic trigger.
An explicit manual dispatch with `confirm_active=true` runs that workflow once
while its switch is off. `dry_run=true` validates without creating a candidate,
tag, release or publisher run. Do not dispatch a non-dry-run stable publication
merely to test configuration.

### GitHub App

Create a GitHub App installed on this repository (recommended name:
`pinchflat-release-automation`). Grant these repository permissions:

| Permission    | Access         | Why                                                                                            |
| ------------- | -------------- | ---------------------------------------------------------------------------------------------- |
| Contents      | Read and write | Push the candidate branch, create tags and releases, merge `master` into `dev`.                |
| Pull requests | Read and write | Create and refresh the release PR, manage duplicate PRs, create the `master` -> `dev` sync PR. |
| Checks        | Read           | Read required check runs on the exact merge commit.                                            |
| Actions       | Read and write | Read publisher runs and dispatch `docker_release.yml` for retries.                             |
| Metadata      | Read           | Required by GitHub.                                                                            |
| Packages      | Read           | Inspect published container manifests when the package is private.                             |

The workflows currently accept a fine-grained PAT in repository secret
`RELEASE_AUTOMATION_TOKEN`, with the permissions above and access to this repository.
Set an expiry and rotate it before expiry. They do not consume
`RELEASE_BOT_APP_ID` or `RELEASE_BOT_PRIVATE_KEY`. A GitHub App integration must mint
fresh installation tokens at runtime; do not store an installation token as a
long-lived secret, because it expires after one hour.
[GitHub App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).

If the secret is absent, the workflows use `github.token`. The repository must
allow Actions to create pull requests. Token-created candidate PR checks can
require a maintainer to select **Approve workflows to run**. Explicit publisher
dispatch works with either credential type. Managed releases carry a hidden
publisher marker: `docker_release.yml` skips their release event and builds only
through dispatch. Ordinary manually published releases retain the release-event
publisher. Keep the marker when editing managed release notes.
[GitHub token event behavior](https://docs.github.com/en/actions/concepts/security/github_token).

### Branch protection

The publish job escalates exactly these job permissions:

```yaml
permissions:
  contents: write
  pull-requests: write
  checks: read
  actions: write
  packages: read
```

Protect `master` so the release PR can be merged as a merge commit:

- Require a pull request before merging.
- Allow merge commits. Do not require squash or rebase merges. The publish step
  verifies that the approved candidate head is a parent of the merge commit.
- Require the SQLite, PostgreSQL, and PostgreSQL schema migration checks.
- Do not require linear history.
- Allow the automation identity to push `release/stable-candidate` and create
  tags/releases. If tag protection rules exist, allow the App to create tags and
  forbid everyone from moving or deleting them.
- Keep `dev` open for the automated `master` -> `dev` merge or sync PR.

### Actions and registry settings

- Workflow permissions default to read-only. The release jobs escalate only the
  permissions they need.
- Allow GitHub Actions to create and approve pull requests if you use the
  `github.token` fallback.
- The existing `docker_release.yml` must remain the only stable image publisher.
  It owns the `latest`, `latest-postgres`, version, and version-postgres tags.
- The publish job needs Docker Buildx on the runner (`docker/setup-buildx-action`
  is pinned in the workflow) to inspect the published manifests.

## Maintainer workflow

1. Merge normal feature and fix PRs into `dev`.
2. The candidate workflow runs on every `dev` push. It creates or refreshes the
   single `release/stable-candidate` -> `master` PR.
3. Review the PR:
   - Confirm the proposed version and previous stable tag in the generated
     metadata.
   - Review the bounded generated change list.
   - Write the release notes inside `<!-- RELEASE-NOTES-START -->` and
     `<!-- RELEASE-NOTES-END -->`. Follow `.github/RELEASE_NOTES.md`.
   - Complete every checklist item after checking the current candidate. Leave
     machine metadata alone.
4. Wait for the required checks on the candidate.
5. Merge the PR with a **merge commit**. Do not squash or rebase.
6. The publish workflow runs on the `master` push. It:
   - Confirms the commit is the merge commit of the release candidate PR.
   - Confirms the merged metadata matches the candidate head, source, baseline,
     version, and tag.
   - Waits for the SQLite, PostgreSQL, and schema migration checks on the exact
     merge commit.
   - Creates the `YEAR.MONTH.PATCH` tag and the GitHub Release with the
     maintainer notes, excluding internal checklists and metadata.
   - Dispatches `docker_release.yml` with the stable inputs. Its hidden marker
     suppresses the matching release-event build, including a delayed event.
   - Verifies the four stable manifests, then merges `master` into `dev` or
     opens a sync PR when the direct merge conflicts.
7. Verify the release page, the container tags, and the `dev` synchronization.

A refresh preserves maintainer notes but invalidates prior acceptance evidence:
the metadata records a new candidate head and an `invalidated` acceptance status,
and every checked checklist item is reset. Recheck the refreshed candidate before
checking the items again. A status field alone cannot approve publication.

## PR body markers

The release PR body is machine-managed only in bounded regions:

```text
<!-- GENERATED-CHANGES-START --> ... <!-- GENERATED-CHANGES-END -->
<!-- RELEASE-NOTES-START -->     ... <!-- RELEASE-NOTES-END -->
<!-- RELEASE-FOOTER-START -->    ... <!-- RELEASE-FOOTER-END -->
<!-- INTERNAL-CHECKLIST-START --> ... <!-- INTERNAL-CHECKLIST-END -->
<!-- RELEASE-METADATA-START -->  ... <!-- RELEASE-METADATA-END -->
```

- Generated changes are replaced on every refresh.
- Maintainer notes are preserved.
- The footer inside the notes region is regenerated with the current image-tag
  table and version-range changelog. A complete, correctly formatted handwritten
  footer is preserved without duplication. Handwritten stale tags or malformed
  footers block publication; update them or leave the footer to the generator.
- The internal checklist is never published.
- Metadata is the only source of the source SHA, baseline, candidate head,
  proposed version, tag, and previous stable tag. Duplicate or spoofed metadata
  blocks stop publication.

## Failure and resume

| Symptom                                              | Action                                                                                                                                             |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Candidate merge conflict                             | Resolve the conflict on `dev` through a normal PR, then rerun the candidate workflow. The automation never force-pushes over a conflict.           |
| Candidate push rejected                              | Another run changed the branch. Rerun; the lease check prevents overwriting the newer candidate.                                                   |
| Version/date error                                   | Fix the clock/override or provide `bootstrap_version` on the first automated release.                                                              |
| Tag collision                                        | Investigate the existing tag. Never delete or move a published tag; publish a new patch instead.                                                   |
| Missing, skipped, cancelled, stale, or failed checks | Fix the cause on `dev` and let the candidate refresh. The merge commit must have all three required checks.                                        |
| Checks still running                                 | Rerun the publish workflow with `checks_wait_seconds` long enough to cover the CI run.                                                             |
| Validation failed before tagging                     | Fix the metadata or candidate, merge the refreshed release PR, and rerun. No tag or release exists.                                                |
| Tag and release exist, publisher failed              | Rerun `release_publish.yml`. It dispatches one retry and never moves the tag or recreates the release.                                             |
| Publisher still running                              | The workflow exits with `publisher_pending` and does not sync `dev`. Rerun later; the completed run is detected and no duplicate dispatch is made. |
| Registry verification failed                         | Wait for registry propagation or check the publisher, then rerun. Tags stay immutable.                                                             |
| `master` -> `dev` sync conflict                      | Resolve the generated sync PR normally. Do not rewrite the release tag.                                                                            |
| Wrong release notes                                  | Edit the GitHub Release body manually. The tag and images are already published; do not rerun the publisher to change notes.                       |

## Manual commands

```bash
# Prepare or refresh a candidate for the current dev head
gh workflow run release_candidate.yml --repo TheBadFella/Pinchflat-NGX

# Prepare with an explicit version override or first-release bootstrap
gh workflow run release_candidate.yml \
  --repo TheBadFella/Pinchflat-NGX \
  -f version_override=2026.12.0
gh workflow run release_candidate.yml \
  --repo TheBadFella/Pinchflat-NGX \
  -f bootstrap_version=2026.11.0

# Validate and publish a specific merge commit
gh workflow run release_publish.yml \
  --repo TheBadFella/Pinchflat-NGX \
  -f sha=<merge-commit-sha>

# Retry the publisher explicitly after a failure
gh workflow run release_publish.yml \
  --repo TheBadFella/Pinchflat-NGX \
  -f sha=<merge-commit-sha>
```

## Local verification

Run the acceptance suite in an isolated Docker development container with git and
PyYAML installed (the dev image includes both). It uses temporary repositories and
fake APIs, with no credentials or real media:

```bash
docker compose run --rm --no-deps --entrypoint python3 phx -m unittest discover -s test/tooling -p 'test_*.py' -v
```

The suite covers version/timezone boundaries, invalid overrides and tag
collisions, no-change runs, idempotent and concurrent preparation, note
preservation and approval invalidation, master hotfixes and conflicts, all CI
blocking states, tag/release reuse, deterministic publisher routing, spoofed metadata and literal shell-injection notes, publisher
failure/retry/pending handling, manifest verification, and `master` -> `dev`
synchronization.

Validate the workflow YAML with the repository's normal `actionlint` pre-commit
hook when available.

## Rollback and rollforward

Git release tags stay fixed. A failed container build can be retried from the same
commit, but upstream dependency refreshes can change the rebuilt image digest.
Use the recorded manifest digest when you need an exact artifact. Do not rerun a
successful publisher just to edit notes. If a release is wrong:

1. Do not delete, move, or re-point the tag.
2. Revert the offending change on `dev` and merge a fix.
3. Prepare the next patch release through the normal candidate flow.
4. If the GitHub Release body is wrong, edit the body directly; do not rerun the
   publish workflow just to change notes.

## First automated release

When no published stable release exists, the candidate workflow stops with
`missing_baseline`. Rerun it with `bootstrap_version` set to the first
`YEAR.MONTH.PATCH`. After that release exists, normal version increments apply.
