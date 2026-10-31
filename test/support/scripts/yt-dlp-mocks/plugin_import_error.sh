#!/bin/bash

# Simulates yt-dlp reporting a plugin import failure while still succeeding.
echo "Error while importing module 'yt_dlp_plugins.postprocessor.sample'" >&2
echo "ModuleNotFoundError: No module named 'sample_plugin'" >&2

exec "$(dirname "$0")/repeater.sh" "$@"
