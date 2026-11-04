#!/bin/bash
set -euo pipefail

# Use an explicit year.month.patch version instead of treating the day as a patch number.
if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[0-9]{4}\.([1-9]|1[0-2])\.(0|[1-9][0-9]*)$ ]]; then
  echo "Usage: $0 YEAR.MONTH.PATCH (for example 2026.11.0)" >&2
  exit 1
fi

NEXT_VERSION="$1"
CURRENT_VERSION=$(grep 'version: ' mix.exs | cut -d '"' -f2)

echo "Bumping version from $CURRENT_VERSION to $NEXT_VERSION"
sed -i "s/version: \"$CURRENT_VERSION\"/version: \"$NEXT_VERSION\"/g" mix.exs
mix check

echo "Version bumped successfully to $NEXT_VERSION"
