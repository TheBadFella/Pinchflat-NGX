#!/bin/bash

# Simulates a matching video: both filter stages run and after_move writes JSON.

for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" == "--print-to-file" ]; then
    template="${@:i+1:1}"
    file="${@:i+2:1}"

    case "$template" in
      pre_process:pinchflat-pre-process | after_filter:pinchflat-after-filter)
        echo "${template%%:*}" >>"$file"
        ;;
      after_move:*)
        echo '{"id":"abc","title":"Old video"}' >"$file"
        ;;
    esac
  fi
done

exit 0
