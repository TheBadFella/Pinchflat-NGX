#!/bin/sh
# Stands in for a freshly downloaded yt-dlp nightly build.
if [ "$1" = "--version" ]; then
  echo "2026.11.05"
  exit 0
fi

if [ "$1" = "--ignore-config" ]; then
  echo "Usage: yt-dlp [OPTIONS] URL [URL...]" >&2
  echo "yt-dlp: error: You must provide at least one URL" >&2
  exit 2
fi

echo "downloaded nightly candidate"
exit 0
