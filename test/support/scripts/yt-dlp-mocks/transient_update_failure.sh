#!/bin/sh
# Emulates a yt-dlp self-update that fails with a transient network error.
if [ "$1" = "--version" ]; then
  echo "2026.11.04"
  exit 0
fi

if [ "$1" = "--update-to" ]; then
  echo "ERROR: Unable to obtain version info: temporary failure"
  exit 1
fi

if [ "$1" = "--ignore-config" ]; then
  echo "Usage: yt-dlp [OPTIONS] URL [URL...]" >&2
  echo "yt-dlp: error: You must provide at least one URL" >&2
  exit 2
fi

echo "ok"
exit 0
