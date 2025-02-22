.PHONY: build run

build:
	podman build -t spuder/packpoint . --no-cache

run:
	podman run --env-file .env -p 9292:9292 localhost/spuder/packpoint:latest

all: build run