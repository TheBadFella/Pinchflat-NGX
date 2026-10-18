# Development images

Use **Actions > Build Dev Image > Run workflow** and select the branch to test.
The workflow checks out the selected run's exact commit and builds the normal
production Dockerfile. AMD64 is the default; select both platforms for AMD64 and
ARM64 images. Both SQLite and PostgreSQL variants are built.

| Database   | Moving tag                                       | Commit tag                                                         |
| ---------- | ------------------------------------------------ | ------------------------------------------------------------------ |
| SQLite     | `ghcr.io/thebadfella/pinchflat-ngx:dev`          | `ghcr.io/thebadfella/pinchflat-ngx:dev-<full-commit-sha>`          |
| PostgreSQL | `ghcr.io/thebadfella/pinchflat-ngx:dev-postgres` | `ghcr.io/thebadfella/pinchflat-ngx:dev-<full-commit-sha>-postgres` |

The run summary lists the published tags. `dev` follows the most recently
published development build, regardless of branch. A commit tag identifies the
source; rebuilding that commit can update dependencies such as yt-dlp. Pin an
image digest to retain an exact build. An AMD64-only run replaces the moving tag
with an AMD64-only image; choose both platforms when ARM64 testers need it.

This workflow has no stable-tag or GitHub Release publication step. It does not
run the application test suite; run **Perform linting and run tests** on the same
branch before accepting a development build.

For a disposable SQLite test instance, save this as `compose.yaml` in a new,
empty directory:

```yaml
name: pinchflat-ngx-dev-test

services:
  pinchflat:
    image: ghcr.io/thebadfella/pinchflat-ngx:dev
    ports:
      - '8946:8945'
    environment:
      TZ: America/Regina
    volumes:
      - ./config:/config
      - ./downloads:/downloads
```

Run these commands from that directory in PowerShell or Bash:

```sh
docker compose pull
docker compose up -d
```

Open <http://localhost:8946>. Repeat the commands to pull and start a newer build.
Keep this instance's config, database and media separate from your regular
instance. Use a copied backup if you need realistic data; changing back to a
stable image does not undo database migrations. PostgreSQL testing also needs
its own database and the usual PostgreSQL connection settings.
