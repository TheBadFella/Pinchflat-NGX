# https://just.systems

default: dev

dev: clear
    docker compose build && docker compose up -d && docker attach pinchflat-phx-1

rebuild:
    docker compose up --build -d

rebuild-phx:
    docker compose up --build -d phx

clear:
    clear

down: clear
    docker compose down

test: clear
    docker compose run --rm phx mix test

