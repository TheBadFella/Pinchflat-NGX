# Source control follow-up

Base: merged recovery fix `9677e00` (PR #139).
Branch: `fix/source-pause-downloads`. This is the validation snapshot prepared for publication.

The next product request is multi-source control, based on [the feedback under issue #99](https://github.com/TheBadFella/Pinchflat-NGX/issues/99#issuecomment-6218946328). The first prerequisite is reliable Pause and Stop behavior for the existing single-source controls. No multi-selection UI or bulk cutoff editor has been added yet.

## Confirmed defect and fix

The Pause and Stop endpoints detected an active replacement job, disabled source downloads and reported success, but the cancellation helper only visited media without a downloaded file. The replacement therefore continued executing.

The shared cancellation helper now queries queued download tasks belonging to the source, including downloaded, filtered or otherwise non-pending media. It includes executing jobs only when explicitly requested. It preserves other worker types and other sources' work. No media files are deleted.

The returned count now reflects the number of media items whose matching download tasks were removed, rather than all media currently eligible for an initial download.

## Verification

- Two controller regressions failed before the fix: Pause and Stop both left the replacement job executing.
- The affected helper/controller checks passed: 102 tests, zero failures.
- Full Docker checks passed on both adapters: 2,284 test definitions, zero failures; SQLite excluded 36 and PostgreSQL excluded 47 by their normal schema/adapter selections. Compiler, formatter, Credo, security and JavaScript checks also passed.
- A packaged SQLite UI check held an external fixture downloader in flight and clicked the existing Pause button. Before the fix, the success message appeared while the job remained executing. After the fix, the job was cancelled and the downloader process was absent; the original media's SHA256 was unchanged.
- The packaged check uses a synthetic external downloader. PostgreSQL coverage is automated rather than a second packaged UI run. No UI styling changed.

Evidence, including failed harness attempts and the before/after reports, is retained in `D:/Git/PinchYT-source-controls-validation`. The initial runtime harness expected a status role where the existing flash uses alert; a repeated attempt also exposed a stale fixture hold marker. Both harness assumptions were corrected before recording the actual before/after results.

PR #139 is separately merged and has green PR/master CI. The PR records the final commit and CI results for this source-control follow-up. The original checkout remains untouched. No release, registry publication or deployment was performed.
