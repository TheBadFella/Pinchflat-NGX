#!/bin/bash

# Simulates yt-dlp exiting 0 for a video rejected by --match-filter.

for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" == "--print-to-file" ]; then
    template="${@:i+1:1}"
    file="${@:i+2:1}"

    if [ "$template" == "pre_process:pinchflat-pre-process" ]; then
      echo "pinchflat-pre-process" >>"$file"
    fi
  fi
done

echo "[download] Newer video does not pass filter (upload_date < 20200101), skipping .."
exit 0
