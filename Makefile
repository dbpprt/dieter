.PHONY: build install proto test test-race check hooks pre-commit run clean

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

proto:
	./scripts/generate-proto.sh

build:
	go build -trimpath -o bin/dieter ./cmd/dieter
	go build -trimpath -o bin/dieter-gateway ./cmd/dieter-gateway

install: build
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 bin/dieter "$(DESTDIR)$(BINDIR)/dieter"

test:
	go test ./...

test-race:
	go test -race ./...

check: proto test-race
	go vet ./...
	go build -trimpath -o bin/dieter ./cmd/dieter
	go build -trimpath -o bin/dieter-gateway ./cmd/dieter-gateway

hooks:
	@command -v pre-commit >/dev/null || { echo "pre-commit is required; install it with: brew install pre-commit" >&2; exit 1; }
	pre-commit install --install-hooks

pre-commit:
	@command -v pre-commit >/dev/null || { echo "pre-commit is required; install it with: brew install pre-commit" >&2; exit 1; }
	pre-commit run --all-files

run:
	go run ./cmd/dieter serve

clean:
	rm -f bin/dieter bin/dieter-gateway coverage.out
