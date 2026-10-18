# Operator documentation draft

These notes document the reliability corrections for operators. They are a draft for a separate wiki update.

## API access

General API routes require the existing `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD` credentials when Basic Auth or OIDC is configured. This includes library reads, profile changes, deletion and download actions. API clients send HTTP Basic Auth credentials; browser OIDC cookies do not authorize these calls. Use HTTPS outside a trusted network.

An installation using OIDC alone rejects general API access until Basic Auth credentials are configured. Installations with neither authentication method configured retain their existing unauthenticated API behavior.

Health checks and the OpenAPI specification remain public. Podcast routes keep their existing access rules. Share intake continues to require a scoped sharing token.

Enqueue actions distinguish newly accepted work, duplicate work and failure. A failed enqueue returns HTTP 503 rather than claiming that a job was created. Batch actions report counts; a partial failure also returns 503. Queue acceptance does not mean a download has completed.

## Source import

Upload a text file with one source URL per line, select a profile, then review the URLs before confirming. The existing limits remain 100 URLs and 100 KB. Repeated lines are removed before import.

The page checks one source at a time and reports progress and per-source outcomes. Cancel stops after the source currently being checked. Sources already added are retained. Keep the page open; this bounded import does not resume automatically after closing the page or restarting the app. Reimporting an existing source uses the normal uniqueness checks.

New sources can begin indexing and downloading under their normal settings. The preview explicitly discloses this before confirmation. CSV intake and bulk source editing are outside this correction.

## SQLite to PostgreSQL

The transfer now accepts current sharing and completed legacy-review records, reads SQLite nested subtitle and job-error arrays through the adapter, and preserves retired allocation IDs. An unfinished legacy review still blocks transfer. Failed transfers roll back sequence changes with copied rows. The normal post-transfer review and restart requirements remain in force.

During PostgreSQL transfer review, general API writes are held as well. Authenticated clients can read the retained library for review; writes return HTTP 423 until review is completed.
