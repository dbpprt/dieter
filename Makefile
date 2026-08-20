.PHONY: build proto test test-race check hooks pre-commit run clean

proto:
	./scripts/generate-proto.sh

build:
	go build -trimpath -o bin/nauclio ./cmd/nauclio
	go build -trimpath -o bin/nauclio-gateway ./cmd/nauclio-gateway

test:
	go test ./...

test-race:
	go test -race ./...

check: proto test-race
	go vet ./...
	go build -trimpath -o bin/nauclio ./cmd/nauclio
	go build -trimpath -o bin/nauclio-gateway ./cmd/nauclio-gateway

hooks:
	@command -v pre-commit >/dev/null || { echo "pre-commit is required; install it with: brew install pre-commit" >&2; exit 1; }
	pre-commit install --install-hooks

pre-commit:
	@command -v pre-commit >/dev/null || { echo "pre-commit is required; install it with: brew install pre-commit" >&2; exit 1; }
	pre-commit run --all-files

run:
	go run ./cmd/nauclio serve

clean:
	rm -f bin/nauclio bin/nauclio-gateway coverage.out
