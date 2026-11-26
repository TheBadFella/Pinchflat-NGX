#!/bin/sh
# Emulates a yt-dlp candidate that does not understand --js-runtimes.
if [ "$1" = "--version" ]; then
  echo "2026.11.04"
  exit 0
fi

if [ "$1" = "--ignore-config" ]; then
  echo "Usage: yt-dlp [OPTIONS] URL [URL...]" >&2
  echo "yt-dlp: error: no such option: --js-runtimes" >&2
  exit 2
fi

echo "updated"
exit 0
