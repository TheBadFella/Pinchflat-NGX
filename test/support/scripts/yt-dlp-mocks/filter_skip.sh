#!/bin/bash

# Simulates yt-dlp exiting 0 for a video rejected by --datebefore. Unlike a
# successful download, it writes the pre_process stage marker but never reaches
# after_filter or after_move, so the JSON output file stays empty.

for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" == "--print-to-file" ]; then
    template="${@:i+1:1}"
    file="${@:i+2:1}"

    if [ "$template" == "pre_process:pinchflat-pre-process" ]; then
      echo "pinchflat-pre-process" >>"$file"
    fi
  fi
done

echo "[download] 2021-01-12 upload date is not in range 0001-01-01 to 2020-01-11"
exit 0
