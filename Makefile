.PHONY: build run dev all

build:
	podman build -t spuder/packpoint . --no-cache

run:
	# podman run --env-file .env -p 9292:9292 localhost/spuder/packpoint:latest
	podman compose -f compose.dev.yaml up --build

dev:
	bundle exec rackup --host 0.0.0.0 --port 9292

all: build run