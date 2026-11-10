#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
identity="${script_dir}/rel/overlays/bin/startup_identity"
runtime_setup="${script_dir}/rel/overlays/bin/runtime_setup"
tmp="$(mktemp -d)"
trap 'status=$?; if [ "$status" -ne 0 ] && [ -f "$tmp/out" ]; then echo "--- captured output ---" >&2; cat "$tmp/out" >&2; fi; rm -rf "$tmp"' EXIT

chmod 755 "$tmp"

unset PUID PGID FIX_PERMISSIONS
unset CONFIG_PATH MEDIA_PATH EXTRAS_PATH METADATA_PATH LOG_PATH
unset POSTGRES_BACKUP_PATH TZ_DATA_PATH DATABASE_PATH DOWNLOAD_STAGING_PATH

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_failure() {
  description="$1"
  shift

  if "$@" >"$tmp/out" 2>&1; then
    fail "$description unexpectedly succeeded"
  fi
}

assert_owner() {
  path="$1"
  expected="$2"
  actual="$(stat -c '%u:%g' "$path" 2>/dev/null)" || fail "could not stat owner of $path"

  [ "$actual" = "$expected" ] || fail "$path is owned by $actual, expected $expected"
}

assert_mode() {
  path="$1"
  expected="$2"
  actual="$(stat -c '%a' "$path" 2>/dev/null)" || fail "could not stat mode of $path"

  [ "$actual" = "$expected" ] || fail "$path has mode $actual, expected $expected"
}

assert_no_zero_group() {
  groups="$1"

  case " $groups " in
    *" 0 "*) fail "supplementary group 0 survived privilege drop: $groups" ;;
  esac
}

assert_zero_capability() {
  label="$1"
  value="$2"

  [ "$value" = "0000000000000000" ] || fail "$label was '$value' after privilege drop"
}

if [ "$(id -u)" != "0" ]; then
  echo "docker_start tests must run as root in a disposable Linux container" >&2
  exit 1
fi

fixture="${tmp}/fixture.sh"
cat >"$fixture" <<'FIXTURE'
#!/bin/sh
set -eu
. "$STARTUP_IDENTITY_LIB"
pin_apply_startup_identity "$0" "$@"

echo "stage_uid=$(id -u)"
echo "stage_gid=$(id -g)"
echo "stage_groups=$(id -G)"
echo "stage_capeff=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)"
echo "stage_capprm=$(sed -n 's/^CapPrm:[[:space:]]*//p' /proc/self/status)"
echo "stage_capinh=$(sed -n 's/^CapInh:[[:space:]]*//p' /proc/self/status)"
echo "stage_capamb=$(sed -n 's/^CapAmb:[[:space:]]*//p' /proc/self/status)"

if [ -n "${FIXTURE_WRITE_DIR:-}" ]; then
  printf 'written\n' >"${FIXTURE_WRITE_DIR}/written-by-stage"
fi
FIXTURE
chmod 755 "$fixture"

runtime_fixture="${tmp}/runtime_fixture.sh"
cat >"$runtime_fixture" <<'FIXTURE'
#!/bin/sh
set -eu
. "$STARTUP_IDENTITY_LIB"
pin_apply_startup_identity "$0" "$@"
. "$RUNTIME_SETUP_LIB"

echo "runtime_uid=$(id -u)"
FIXTURE
chmod 755 "$runtime_fixture"

run_fixture() {
  env STARTUP_IDENTITY_LIB="$identity" "$@" "$fixture"
}

run_runtime_fixture() {
  env STARTUP_IDENTITY_LIB="$identity" RUNTIME_SETUP_LIB="$runtime_setup" "$@" "$runtime_fixture"
}

stage_value() {
  key="$1"
  sed -n "s/^${key}=//p" "$tmp/out" | tail -n 1
}

# 1. Neither variable set preserves the starting identity.
run_fixture >"$tmp/out" 2>&1
[ "$(stage_value stage_uid)" = "$(id -u)" ] || fail "unset pair changed the starting UID"
[ "$(stage_value stage_gid)" = "$(id -g)" ] || fail "unset pair changed the starting GID"
grep -q 'dropping privileges' "$tmp/out" && fail "unset pair reported a privilege drop"

# 2. GID, GUID and TUID are not aliases for PUID/PGID.
run_fixture GID=12345 GUID=12345 TUID=12345 >"$tmp/out" 2>&1
[ "$(stage_value stage_uid)" = "$(id -u)" ] || fail "GID/GUID/TUID alias changed the starting UID"

# 3. A partial pair fails before any configured directory is created.
invalid_root="${tmp}/invalid-pair"
expect_failure "PUID without PGID" \
  run_fixture PUID=1000 CONFIG_PATH="${invalid_root}/config" MEDIA_PATH="${invalid_root}/downloads"
grep -q 'PUID and PGID must be set together' "$tmp/out" || fail "partial pair was not reported"
[ ! -e "$invalid_root" ] || fail "partial pair created a configured directory"

expect_failure "PGID without PUID" \
  run_fixture PGID=1000 CONFIG_PATH="${invalid_root}/config" MEDIA_PATH="${invalid_root}/downloads"
grep -q 'PUID and PGID must be set together' "$tmp/out" || fail "partial pair was not reported"

expect_failure "empty PUID" \
  run_fixture PUID= PGID=1000 CONFIG_PATH="${invalid_root}/config" MEDIA_PATH="${invalid_root}/downloads"
grep -q 'PUID must not be empty' "$tmp/out" || fail "empty PUID was not reported"

expect_failure "empty pair" \
  run_fixture PUID= PGID= CONFIG_PATH="${invalid_root}/config" MEDIA_PATH="${invalid_root}/downloads"
grep -q 'must not be empty' "$tmp/out" || fail "empty pair was not reported"

# 4. Malformed IDs and invalid FIX_PERMISSIONS fail before writes.
for invalid_case in \
  'zero:PUID=0 PGID=1000' \
  'negative:PUID=-100 PGID=1000' \
  'nonnumeric:PUID=1000abc PGID=1000' \
  'injection:PUID=1000;id PGID=1000' \
  'overflow:PUID=2147483648 PGID=1000' \
  'huge:PUID=99999999999999999999 PGID=1000' \
  'pgid-zero:PUID=1000 PGID=0' \
  'pgid-nonnumeric:PUID=1000 PGID=nope'; do
  description="${invalid_case%%:*}"
  assignment="${invalid_case#*:}"

  # shellcheck disable=SC2086
  expect_failure "$description ID" \
    run_fixture $assignment CONFIG_PATH="${invalid_root}/config" MEDIA_PATH="${invalid_root}/downloads"
done
[ ! -e "$invalid_root" ] || fail "invalid IDs created a configured directory"

expect_failure "FIX_PERMISSIONS without a pair" run_fixture FIX_PERMISSIONS=1
grep -q 'FIX_PERMISSIONS is only available when PUID and PGID' "$tmp/out" ||
  fail "FIX_PERMISSIONS without a pair was not reported"

expect_failure "explicit FIX_PERMISSIONS=0 without a pair" run_fixture FIX_PERMISSIONS=0
grep -q 'FIX_PERMISSIONS is only available when PUID and PGID' "$tmp/out" ||
  fail "explicit FIX_PERMISSIONS=0 without a pair was not reported"

expect_failure "unsupported FIX_PERMISSIONS" \
  run_fixture PUID=12345 PGID=12346 FIX_PERMISSIONS=true \
  CONFIG_PATH="${invalid_root}/config" MEDIA_PATH="${invalid_root}/downloads"
grep -q 'FIX_PERMISSIONS must be 0 or 1' "$tmp/out" || fail "unsupported FIX_PERMISSIONS was not reported"
[ ! -e "$invalid_root" ] || fail "unsupported FIX_PERMISSIONS created a configured directory"

# 5. A non-root container with a matching pair uses the direct path without repair.
nonroot_root="${tmp}/nonroot"
expect_failure "non-root FIX_PERMISSIONS" \
  setpriv --reuid 99 --regid 100 --clear-groups --nnp -- \
  env STARTUP_IDENTITY_LIB="$identity" PUID=99 PGID=100 FIX_PERMISSIONS=1 \
  CONFIG_PATH="${nonroot_root}/config" MEDIA_PATH="${nonroot_root}/downloads" "$fixture"
grep -q 'FIX_PERMISSIONS is only available when the container starts as root' "$tmp/out" ||
  fail "non-root FIX_PERMISSIONS was not reported"

setpriv --reuid 99 --regid 100 --clear-groups --nnp -- \
  env STARTUP_IDENTITY_LIB="$identity" PUID=99 PGID=100 \
  CONFIG_PATH="${nonroot_root}/config" MEDIA_PATH="${nonroot_root}/downloads" "$fixture" \
  >"$tmp/out" 2>&1
[ "$(stage_value stage_uid)" = "99" ] || fail "matching non-root pair did not keep UID 99"
[ "$(stage_value stage_gid)" = "100" ] || fail "matching non-root pair did not keep GID 100"
grep -q 'ownership preparation is unavailable without root' "$tmp/out" ||
  fail "matching non-root pair did not report unavailable preparation"
[ ! -e "$nonroot_root" ] || fail "matching non-root pair created configured directories"

expect_failure "non-root pair mismatch" \
  setpriv --reuid 99 --regid 100 --clear-groups --nnp -- \
  env STARTUP_IDENTITY_LIB="$identity" PUID=99 PGID=101 \
  CONFIG_PATH="${nonroot_root}/config" MEDIA_PATH="${nonroot_root}/downloads" "$fixture"
grep -q 'does not match the container' "$tmp/out" || fail "non-root pair mismatch was not reported"
[ ! -e "$nonroot_root" ] || fail "non-root pair mismatch created configured directories"

# 6. A root start prepares approved top-level directories and drops privileges.
base="${tmp}/prepare"
config="${base}/config"
media="${base}/downloads"
extras="${base}/extras"
metadata="${base}/metadata"
log_dir="${base}/logs"
backup="${base}/backups"
tzdata="${base}/tzdata"
database_dir="${base}/db"
staging="${base}/staging"
outside="${base}/outside"

mkdir -p "${config}/nested" "${media}/nested" "$outside"
printf 'keep\n' >"${config}/nested/keep.txt"
printf 'keep\n' >"${media}/nested/keep.txt"
printf 'keep\n' >"${outside}/secret.txt"

run_fixture PUID=12345 PGID=12346 DATABASE_ADAPTER=sqlite \
  CONFIG_PATH="$config" MEDIA_PATH="$media" EXTRAS_PATH="$extras" \
  METADATA_PATH="$metadata" LOG_PATH="${log_dir}/pinchflat.log" \
  POSTGRES_BACKUP_PATH="$backup" TZ_DATA_PATH="$tzdata" \
  DATABASE_PATH="${database_dir}/pinchflat.db" DOWNLOAD_STAGING_PATH="$staging" \
  FIXTURE_WRITE_DIR="$config" >"$tmp/out" 2>&1

[ "$(stage_value stage_uid)" = "12345" ] || fail "root preparation did not drop to UID 12345"
[ "$(stage_value stage_gid)" = "12346" ] || fail "root preparation did not drop to GID 12346"
assert_no_zero_group "$(stage_value stage_groups)"
assert_zero_capability CapEff "$(stage_value stage_capeff)"
assert_zero_capability CapPrm "$(stage_value stage_capprm)"
assert_zero_capability CapInh "$(stage_value stage_capinh)"
assert_zero_capability CapAmb "$(stage_value stage_capamb)"

for prepared in "$config" "$media" "$extras" "$metadata" "$log_dir" "$backup" "$tzdata" "$database_dir" "$staging"; do
  assert_owner "$prepared" "12345:12346"
done

assert_owner "${config}/written-by-stage" "12345:12346"
assert_owner "${config}/nested/keep.txt" "0:0"
assert_owner "${media}/nested/keep.txt" "0:0"
assert_owner "${outside}/secret.txt" "0:0"

# 7. FIX_PERMISSIONS=1 repairs all application state locations but never the media tree.
repair_base="${tmp}/repair"
repair_config="${repair_base}/config"
repair_media="${repair_base}/downloads"
repair_tzdata="${repair_base}/tzdata"
repair_db_dir="${repair_base}/custom_db"
repair_extras="${repair_base}/extras"
repair_staging="${repair_base}/staging"
repair_outside="${repair_base}/outside"

mkdir -p "${repair_config}/nested" "${repair_media}/nested" "${repair_tzdata}/nested" \
  "$repair_db_dir" "$repair_extras" "$repair_staging" "$repair_outside"
printf 'state\n' >"${repair_config}/nested/state.txt"
printf 'tzdata\n' >"${repair_tzdata}/nested/zone.txt"
printf 'sqlite\n' >"${repair_db_dir}/pinchflat.db"
printf 'extras\n' >"${repair_extras}/notes.txt"
printf 'staging\n' >"${repair_staging}/temp.mkv"
printf 'media\n' >"${repair_media}/nested/movie.mkv"
printf 'outside\n' >"${repair_outside}/secret.txt"
printf 'sentinel\n' >"${repair_outside}/sentinel.txt"
ln -s "$repair_outside" "${repair_config}/outside-link"

# Controlled symlink-swap probe: symlink inside repair tree pointing to outside directory
mkdir -p "${repair_config}/swap_tree"
printf 'inner\n' >"${repair_config}/swap_tree/file.txt"
rm -rf "${repair_config}/swap_tree"
ln -s "$repair_outside" "${repair_config}/swap_tree"

run_fixture PUID=12345 PGID=12346 DATABASE_ADAPTER=sqlite FIX_PERMISSIONS=1 \
  CONFIG_PATH="$repair_config" MEDIA_PATH="$repair_media" EXTRAS_PATH="$repair_extras" \
  METADATA_PATH="${repair_base}/metadata" LOG_PATH="${repair_base}/logs/pinchflat.log" \
  POSTGRES_BACKUP_PATH="${repair_base}/backups" TZ_DATA_PATH="$repair_tzdata" \
  DATABASE_PATH="${repair_db_dir}/pinchflat.db" DOWNLOAD_STAGING_PATH="$repair_staging" \
  >"$tmp/out" 2>&1

assert_owner "${repair_config}/nested/state.txt" "12345:12346"
assert_owner "${repair_tzdata}/nested/zone.txt" "12345:12346"
assert_owner "${repair_db_dir}/pinchflat.db" "12345:12346"
assert_owner "${repair_extras}/notes.txt" "12345:12346"
assert_owner "${repair_staging}/temp.mkv" "12345:12346"
assert_owner "${repair_media}/nested/movie.mkv" "0:0"
assert_owner "${repair_outside}/secret.txt" "0:0"
assert_owner "${repair_outside}/sentinel.txt" "0:0"
[ -L "${repair_config}/outside-link" ] || fail "recursive repair followed a symlinked directory"
[ -L "${repair_config}/swap_tree" ] || fail "symlink swap entry was removed or replaced"

# Controlled ancestor-swap probe: ancestor directory is a symlink to outside
mkdir -p "${repair_base}/outside_target"
printf 'outside_target\n' >"${repair_base}/outside_target/target_sentinel.txt"
ln -s "${repair_base}/outside_target" "${repair_base}/ancestor_link"
expect_failure "symlinked ancestor directory" \
  run_fixture PUID=12345 PGID=12346 DATABASE_ADAPTER=sqlite FIX_PERMISSIONS=1 \
  CONFIG_PATH="${repair_base}/ancestor_link/target" MEDIA_PATH="$repair_media"
assert_owner "${repair_base}/outside_target/target_sentinel.txt" "0:0"

# Controlled concurrent ancestor-swap race during execution
race_dir="${repair_base}/race_test"
mkdir -p "${race_dir}/parent/target"
printf 'real\n' >"${race_dir}/parent/target/real.txt"
race_outside="${repair_base}/race_outside"
mkdir -p "${race_outside}/target"
printf 'sentinel\n' >"${race_outside}/target/sentinel.txt"

(
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -L "${race_dir}/parent" ]; then
      rm -f "${race_dir}/parent"
      mkdir -p "${race_dir}/parent/target"
    else
      rm -rf "${race_dir}/parent"
      ln -s "$race_outside" "${race_dir}/parent"
    fi
  done
) &
race_swap_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  run_fixture PUID=12345 PGID=12346 DATABASE_ADAPTER=sqlite FIX_PERMISSIONS=1 \
    CONFIG_PATH="${race_dir}/parent/target" MEDIA_PATH="$repair_media" >/dev/null 2>&1 || true
done
wait "$race_swap_pid" 2>/dev/null || true

assert_owner "${race_outside}/target/sentinel.txt" "0:0"

# 8. Dangerous roots, overlaps, symlinked roots and relative paths fail before writes.
dangerous_base="${tmp}/dangerous"
expect_failure "root config path" run_fixture PUID=12345 PGID=12346 CONFIG_PATH=/
grep -q 'protected system path' "$tmp/out" || fail "root config path was not reported"

expect_failure "etc config path" run_fixture PUID=12345 PGID=12346 CONFIG_PATH=/etc
grep -q 'protected system path' "$tmp/out" || fail "etc config path was not reported"

expect_failure "usr media path" run_fixture PUID=12345 PGID=12346 MEDIA_PATH=/usr
grep -q 'protected system path' "$tmp/out" || fail "usr media path was not reported"

expect_failure "config inside media" \
  run_fixture PUID=12345 PGID=12346 CONFIG_PATH="${dangerous_base}" MEDIA_PATH="${dangerous_base}"
grep -q 'overlap' "$tmp/out" || fail "config/media overlap was not reported"
[ ! -e "$dangerous_base" ] || fail "overlap check created a directory"

expect_failure "tzdata inside media" \
  run_fixture PUID=12345 PGID=12346 MEDIA_PATH="${dangerous_base}/downloads" \
  TZ_DATA_PATH="${dangerous_base}/downloads/tzdata"
grep -q 'overlap' "$tmp/out" || fail "tzdata/media overlap was not reported"

expect_failure "database inside media" \
  run_fixture PUID=12345 PGID=12346 DATABASE_ADAPTER=sqlite MEDIA_PATH="${dangerous_base}/downloads" \
  DATABASE_PATH="${dangerous_base}/downloads/db/pinchflat.db"
grep -q 'overlap' "$tmp/out" || fail "database/media overlap was not reported"

expect_failure "staging inside media" \
  run_fixture PUID=12345 PGID=12346 MEDIA_PATH="${dangerous_base}/downloads" \
  DOWNLOAD_STAGING_PATH="${dangerous_base}/downloads/staging"
grep -q 'overlap' "$tmp/out" || fail "staging/media overlap was not reported"

mkdir -p "${dangerous_base}/real"
ln -s "${dangerous_base}/real" "${dangerous_base}/link"
expect_failure "symlinked config root" \
  run_fixture PUID=12345 PGID=12346 CONFIG_PATH="${dangerous_base}/link"
grep -q 'is a symlink' "$tmp/out" || fail "symlinked config root was not reported"

expect_failure "relative config path" \
  run_fixture PUID=12345 PGID=12346 CONFIG_PATH=relative/config
grep -q 'must be an absolute path' "$tmp/out" || fail "relative config path was not reported"

# 9. Nonzero supplementary groups are retained and group 0 is discarded.
groups_base="${tmp}/groups"
setpriv --reuid 0 --regid 0 --groups 1000 --nnp -- \
  env STARTUP_IDENTITY_LIB="$identity" PUID=12345 PGID=12346 \
  CONFIG_PATH="${groups_base}/config" MEDIA_PATH="${groups_base}/downloads" "$fixture" \
  >"$tmp/out" 2>&1
stage_groups="$(stage_value stage_groups)"
assert_no_zero_group "$stage_groups"
case " $stage_groups " in
  *" 1000 "*) ;;
  *) fail "supplementary group 1000 was not retained: $stage_groups" ;;
esac

# 10. The private runtime tree is created after the drop, as the selected user.
runtime_base="${tmp}/runtime"
seed="${tmp}/seed"
printf '#!/bin/sh\necho seed\n' >"$seed"
chmod 755 "$seed"
mkdir -p "$runtime_base"
chmod 1777 "$runtime_base"

run_runtime_fixture PUID=12345 PGID=12346 \
  CONFIG_PATH="${runtime_base}/config" MEDIA_PATH="${runtime_base}/downloads" \
  PINCHFLAT_RUNTIME_DIR="${runtime_base}/private" PINCHFLAT_YT_DLP_SEED="$seed" \
  >"$tmp/out" 2>&1

[ "$(stage_value runtime_uid)" = "12345" ] || fail "runtime_setup did not run as the dropped UID"
assert_owner "${runtime_base}/private" "12345:12346"
assert_mode "${runtime_base}/private" "700"
assert_owner "${runtime_base}/private/bin/yt-dlp" "12345:12346"
assert_mode "${runtime_base}/private/bin/yt-dlp" "700"

# 11. The internal drop marker cannot be used to skip root preparation.
expect_failure "root with the internal drop marker" \
  env STARTUP_IDENTITY_LIB="$identity" PUID=12345 PGID=12346 \
  CONFIG_PATH="${tmp}/marker/config" MEDIA_PATH="${tmp}/marker/downloads" \
  "$fixture" --pinchflat-privileges-dropped
grep -q 'marker was present while still running as root' "$tmp/out" ||
  fail "internal drop marker was accepted while running as root"

echo "docker_start tests passed"
