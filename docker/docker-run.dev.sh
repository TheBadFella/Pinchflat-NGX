#!/bin/sh

set -e

echo "\nInstalling Elixir deps..."
mix deps.get

# Install both project-level and assets-level JS dependencies
echo "\nInstalling JS deps..."
yarn install && cd assets && yarn install
cd ..

# Potentially set up the database
mix ecto.create
mix ecto.migrate

# Start the Phoenix web server (interactive)
echo "\nLaunching Phoenix web server..."
exec iex -S mix phx.server
