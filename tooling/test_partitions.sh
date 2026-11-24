#!/bin/bash
# Runs the ExUnit suite as parallel partitions, each in its own container.
#
# Usage (from the repository root, after `docker compose up`):
#   tooling/test_partitions.sh [PARTITIONS] [extra mix test args...]
#
# Each partition starts a container from the running `phx` service with
# --volumes-from, so it shares the checkout and the already compiled deps and
# _build, but keeps a private /tmp. That matters because tests use fixed paths
# under /tmp/test and test_helper.exs removes them on exit. Each partition also
# gets its own database: config/runtime.exs appends MIX_TEST_PARTITION to its
# name at boot, so all partitions reuse the one compiled test build.
set -euo pipefail
# Keep Git Bash on Windows from rewriting container paths such as /app.
export MSYS_NO_PATHCONV=1

partitions="${1:-4}"
shift || true

container="$(docker compose ps -q phx)"
if [[ -z "$container" ]]; then
  echo "The phx service is not running; start it with docker compose up first." >&2
  exit 1
fi

image="$(docker inspect -f '{{.Config.Image}}' "$container")"
network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$container")"
logs_dir="$(mktemp -d)"
trap 'rm -rf "$logs_dir"' EXIT

# Reuse the phx container's environment (adapter, database URL and so on).
env_args=()
while IFS= read -r line; do
  [[ -n "$line" ]] && env_args+=(-e "$line")
done < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container")

run_in_container() {
  docker run --rm --volumes-from "$container" --network "$network" "${env_args[@]}" \
    -e MIX_ENV=test -w /app "$@"
}

# Compile once up front: the partitions share _build and must not compile concurrently.
run_in_container "$image" mix compile

pids=()
for partition in $(seq 1 "$partitions"); do
  run_in_container -e "MIX_TEST_PARTITION=${partition}" "$image" \
    mix test --partitions "$partitions" "$@" \
    > "${logs_dir}/${partition}.log" 2>&1 &
  pids+=("$!")
done

status=0
for index in "${!pids[@]}"; do
  partition=$((index + 1))
  if wait "${pids[$index]}"; then
    result="passed"
  else
    result="FAILED"
    status=1
  fi
  echo "::group::Test partition ${partition}/${partitions} ${result}"
  cat "${logs_dir}/${partition}.log"
  echo "::endgroup::"
  echo "Test partition ${partition}/${partitions}: ${result}"
done

exit "$status"
