#!/bin/bash

# Simulates a failure after the media passed filters: both stage markers were
# written but no after_move output exists. This must stay an error, not a skip.

for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" == "--print-to-file" ]; then
    template="${@:i+1:1}"
    file="${@:i+2:1}"

    case "$template" in
      pre_process:pinchflat-pre-process | after_filter:pinchflat-after-filter)
        echo "${template%%:*}" >>"$file"
        ;;
    esac
  fi
done

echo "ERROR: unable to download video data: HTTP Error 500"
exit 0
