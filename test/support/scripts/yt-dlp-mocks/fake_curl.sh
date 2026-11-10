#!/bin/sh
# Minimal curl stand-in: copies FAKE_CURL_SOURCE to the -o target and records it.
target=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      target="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[ -n "$target" ] || { echo "missing -o target" >&2; exit 1; }
[ -n "${FAKE_CURL_SOURCE:-}" ] || { echo "missing FAKE_CURL_SOURCE" >&2; exit 1; }

cp "$FAKE_CURL_SOURCE" "$target" || exit 1

if [ -n "${FAKE_CURL_LOG:-}" ]; then
  printf '%s\n' "$target" > "$FAKE_CURL_LOG"
fi
