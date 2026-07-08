.PHONY: build run dev all

dev:
	bundle exec rackup --host 0.0.0.0 --port 9292

all: build run