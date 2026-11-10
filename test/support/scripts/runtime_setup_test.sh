#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
setup="${script_dir}/rel/overlays/bin/runtime_setup"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

seed="${tmp}/seed"
printf '#!/bin/sh\necho seed\n' >"$seed"
chmod 755 "$seed"

expect_failure() {
  description="$1"
  shift

  if "$@" >"$tmp/out" 2>&1; then
    fail "$description unexpectedly succeeded"
  fi
}

# 1. Seeds a private yt-dlp copy and supplies HOME/TMPDIR.
root="${tmp}/case1"
out="$(env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="$root" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"; printf "%s\n%s\n%s\n" "$PATH" "$HOME" "$TMPDIR"' sh "$setup")"

last_three="$(printf '%s\n' "$out" | tail -n 3)"
path_line="$(printf '%s\n' "$last_three" | sed -n 1p)"
home_line="$(printf '%s\n' "$last_three" | sed -n 2p)"
tmp_line="$(printf '%s\n' "$last_three" | sed -n 3p)"

[ "${path_line%%:*}" = "${root}/bin" ] || fail "PATH does not start with the private bin directory"
[ "$home_line" = "${root}/home" ] || fail "HOME was not redirected to the private home"
[ "$tmp_line" = "${root}/tmp" ] || fail "TMPDIR was not redirected to the private tmp"
[ "$(stat -c %a "${root}/bin/yt-dlp")" = "700" ] || fail "seeded yt-dlp is not mode 700"
cmp -s "$seed" "${root}/bin/yt-dlp" || fail "seeded yt-dlp does not match the image seed"
# 2. A container restart keeps the updated private binary.
printf 'updated binary\n' >"${root}/bin/yt-dlp"
chmod 700 "${root}/bin/yt-dlp"
env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="$root" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup" >/dev/null
[ "$(cat "${root}/bin/yt-dlp")" = "updated binary" ] || fail "restart reseeded over the updated yt-dlp"

# 3. A symlinked runtime directory is rejected.
mkdir "${tmp}/real-runtime"
ln -s "${tmp}/real-runtime" "${tmp}/case3"
expect_failure "symlinked runtime directory" \
  env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="${tmp}/case3" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
grep -q 'is a symlink' "$tmp/out" || fail "symlinked runtime directory was not reported"
# 4. A foreign-owned runtime directory is rejected when the test can create one.
if [ "$(id -u)" = "0" ]; then
  mkdir "${tmp}/case4"
  chown 12345:12345 "${tmp}/case4"
  expect_failure "foreign-owned runtime directory" \
    env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="${tmp}/case4" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
  grep -q 'is owned by uid' "$tmp/out" || fail "foreign ownership was not reported"
fi

# 5. Group/world permissions on a private directory are rejected.
mkdir "${tmp}/case5"
chmod 777 "${tmp}/case5"
expect_failure "group/world-writable runtime directory" \
  env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="${tmp}/case5" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
grep -q 'remove group/world permissions' "$tmp/out" || fail "group/world permissions were not reported"

# 6. An owner-unsearchable directory is rejected.
mkdir "${tmp}/case6"
chmod 000 "${tmp}/case6"
expect_failure "unsearchable runtime directory" \
  env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="${tmp}/case6" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
grep -q 'not readable, writable and searchable' "$tmp/out" || fail "unsearchable directory was not reported"
chmod 700 "${tmp}/case6"
# 7. Valid explicit HOME and TMPDIR are preserved.
mkdir "${tmp}/custom-home" "${tmp}/custom-tmp"
chmod 700 "${tmp}/custom-tmp"
out="$(env HOME="${tmp}/custom-home" TMPDIR="${tmp}/custom-tmp" PINCHFLAT_RUNTIME_DIR="${tmp}/case7" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"; echo "$HOME"; echo "$TMPDIR"' sh "$setup")"
last_two="$(printf '%s\n' "$out" | tail -n 2)"
home_line="$(printf '%s\n' "$last_two" | sed -n 1p)"
tmp_line="$(printf '%s\n' "$last_two" | sed -n 2p)"
[ "$home_line" = "${tmp}/custom-home" ] || fail "valid HOME override was not preserved"
[ "$tmp_line" = "${tmp}/custom-tmp" ] || fail "valid TMPDIR override was not preserved"

# 8. A symlinked TMPDIR override fails clearly.
mkdir "${tmp}/tmp-target"
ln -s "${tmp}/tmp-target" "${tmp}/tmp-link"
expect_failure "symlinked TMPDIR" \
  env HOME="${tmp}/custom-home" TMPDIR="${tmp}/tmp-link" PINCHFLAT_RUNTIME_DIR="${tmp}/case8" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
grep -q 'TMPDIR .* is a symlink' "$tmp/out" || fail "symlinked TMPDIR was not reported"

# 9. A missing seed fails clearly.
expect_failure "missing yt-dlp seed" \
  env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="${tmp}/case9" PINCHFLAT_YT_DLP_SEED="${tmp}/missing-seed" sh -c '. "$1"' sh "$setup"
grep -q 'seed yt-dlp is missing' "$tmp/out" || fail "missing seed was not reported"

# 10. World-writable custom TMPDIR fails.
mkdir "${tmp}/world-tmp"
chmod 777 "${tmp}/world-tmp"
expect_failure "world-writable TMPDIR" \
  env HOME="${tmp}/custom-home" TMPDIR="${tmp}/world-tmp" PINCHFLAT_RUNTIME_DIR="${tmp}/case10" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
grep -q 'remove group/world permissions' "$tmp/out" || fail "world-writable TMPDIR was not reported"

# 11. Mode 0600 yt-dlp fails.
mkdir -p "${tmp}/case11/bin"
chmod 700 "${tmp}/case11" "${tmp}/case11/bin"
cp "$seed" "${tmp}/case11/bin/yt-dlp"
chmod 600 "${tmp}/case11/bin/yt-dlp"
expect_failure "mode 0600 yt-dlp" \
  env -u HOME TMPDIR=/tmp PINCHFLAT_RUNTIME_DIR="${tmp}/case11" PINCHFLAT_YT_DLP_SEED="$seed" sh -c '. "$1"' sh "$setup"
grep -q 'is not executable' "$tmp/out" || fail "mode 0600 yt-dlp was not reported"

echo "runtime_setup tests passed"
