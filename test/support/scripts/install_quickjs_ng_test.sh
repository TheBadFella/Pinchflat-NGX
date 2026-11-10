#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
installer="${script_dir}/docker/install-quickjs-ng.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

# Bad checksum: an asset with the expected name but the wrong bytes.
mkdir -p "$tmp/bad"
printf 'not a quickjs binary\n' >"$tmp/bad/qjs-linux-x86_64"
printf 'not the license\n' >"$tmp/bad/LICENSE"

expect_failure "bad checksum" \
  env TARGETPLATFORM=linux/amd64 QUICKJS_NG_DESTDIR="$tmp/dest-bad" \
  QUICKJS_NG_DOWNLOAD_PREFIX="file://$tmp/bad" \
  QUICKJS_NG_LICENSE_URL="file://$tmp/bad/LICENSE" \
  sh "$installer"

grep -q 'checksum verification failed' "$tmp/out" || fail "bad checksum did not report the failure"
[ ! -e "$tmp/dest-bad/usr/local/bin/qjs" ] || fail "bad checksum installed a qjs binary"
# Failed download: the pinned asset does not exist at the prefix.
expect_failure "failed download" \
  env TARGETPLATFORM=linux/amd64 QUICKJS_NG_DESTDIR="$tmp/dest-missing" \
  QUICKJS_NG_DOWNLOAD_PREFIX="file://$tmp/missing" \
  QUICKJS_NG_LICENSE_URL="file://$tmp/missing/LICENSE" \
  sh "$installer"

grep -q 'Failed to download QuickJS-NG' "$tmp/out" || fail "failed download did not report the failure"
[ ! -e "$tmp/dest-missing/usr/local/bin/qjs" ] || fail "failed download installed a qjs binary"

# Unsupported target: must abort before downloading or installing anything.
expect_failure "unsupported platform" \
  env TARGETPLATFORM=linux/riscv64 QUICKJS_NG_DESTDIR="$tmp/dest-unsupported" \
  sh "$installer"

grep -q 'Unsupported platform for QuickJS-NG' "$tmp/out" || fail "unsupported platform was not reported"
[ ! -e "$tmp/dest-unsupported/usr/local/bin/qjs" ] || fail "unsupported platform installed a qjs binary"

echo "install_quickjs_ng tests passed"
