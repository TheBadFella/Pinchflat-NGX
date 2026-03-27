#!/bin/sh

set -e

MIX_LOCK_HASH_FILE="/app/tmp/.mix_lock.sha256"
ROOT_YARN_LOCK_HASH_FILE="/app/tmp/.root_yarn_lock.sha256"
ASSETS_YARN_LOCK_HASH_FILE="/app/tmp/.assets_yarn_lock.sha256"

mkdir -p /app/tmp

compute_hash() {
  if [ -f "$1" ]; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "missing"
  fi
}

hash_changed() {
  current_hash="$(compute_hash "$1")"
  if [ ! -f "$2" ] || [ "$(cat "$2")" != "$current_hash" ]; then
    echo "$current_hash" > "$2"
    return 0
  fi

  return 1
}

need_mix_install=0
need_root_yarn_install=0
need_assets_yarn_install=0

if [ ! -d /app/deps ] || [ -z "$(ls -A /app/deps 2>/dev/null)" ] || hash_changed /app/mix.lock "$MIX_LOCK_HASH_FILE"; then
  need_mix_install=1
fi

if [ ! -d /app/node_modules ] || [ -z "$(ls -A /app/node_modules 2>/dev/null)" ] || hash_changed /app/yarn.lock "$ROOT_YARN_LOCK_HASH_FILE"; then
  need_root_yarn_install=1
fi

if [ ! -d /app/assets/node_modules ] || [ -z "$(ls -A /app/assets/node_modules 2>/dev/null)" ] || hash_changed /app/assets/yarn.lock "$ASSETS_YARN_LOCK_HASH_FILE"; then
  need_assets_yarn_install=1
fi

echo "\nInstalling Elixir deps..."
if [ "$need_mix_install" -eq 1 ]; then
  mix deps.get
else
  echo "Elixir deps already cached."
fi

# Install both project-level and assets-level JS dependencies
echo "\nInstalling JS deps..."
if [ "$need_root_yarn_install" -eq 1 ]; then
  yarn install --frozen-lockfile
else
  echo "Root JS deps already cached."
fi

if [ "$need_assets_yarn_install" -eq 1 ]; then
  cd assets
  yarn install --frozen-lockfile
  cd ..
else
  echo "Asset JS deps already cached."
fi

# Potentially set up the database
mix ecto.create
mix ecto.migrate

# Start the Phoenix web server (interactive)
echo "\nLaunching Phoenix web server..."
exec iex -S mix phx.server
