#!/usr/bin/env bash

# Enable job control so the background program runs in its own process group
set -m

# Start the program in the background
"$@" &
pid1=$!

# Silence wrapper warnings and job control messages from here on
exec 2>/dev/null

kill_group() {
  local target=$1
  if [ -n "$target" ] && [ "$target" -gt 1 ] 2>/dev/null; then
    kill -TERM -"$target" 2>/dev/null || true
    kill -KILL -"$target" 2>/dev/null || true
    local pids=$(pgrep -g "$target" 2>/dev/null)
    for p in $pids; do
      kill -KILL "$p" 2>/dev/null || true
    done
  fi
}

kill_tree() {
  local target=$1
  if [ -n "$target" ] && [ "$target" -gt 1 ] 2>/dev/null; then
    local children=$(pgrep -P "$target" 2>/dev/null)
    for child in $children; do
      kill_tree "$child"
    done
    kill -KILL "$target" 2>/dev/null || true
  fi
}

cleanup() {
  kill_group "$pid1"
  kill_tree "$pid1"
  kill -KILL "$pid2" 2>/dev/null || true
}

trap cleanup HUP INT TERM

# Read from stdin in the background and
# kill running program tree when stdin closes (EOF)
(
  while read -r line; do :; done
  kill_group "$pid1"
  kill_tree "$pid1"
) 0<&0 &
pid2=$!

# Clean up
wait "$pid1" 2>/dev/null
ret=$?

kill_group "$pid1"
kill_tree "$pid1"
kill -KILL "$pid2" 2>/dev/null || true
exit "$ret"
