set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]

mod mac 'just/mac.just'
mod android 'just/android.just'
mod daemon 'just/daemon.just'
mod gateway 'just/gateway.just'
mod harness 'just/harness.just'
mod site 'just/site.just'
mod release 'just/release.just'

# List the repository commands.
default:
    @just --list

# Verify the platform-neutral tools needed for repository development.
doctor:
    command -v just
    command -v go
    just daemon doctor
    just gateway doctor
    just harness doctor

# Verify every native and platform-neutral development tool.
doctor-all: doctor
    just mac doctor
    just android doctor

# Generate Go clients and synchronize native schema inputs.
proto-core:
    ./scripts/generate-proto.sh

# Generate every checked-in protobuf client.
proto: proto-core
    just mac proto-generate

# Build both Go binaries.
build:
    just daemon build
    just gateway build

# Run the Go test suite.
test:
    go test ./...

# Run the Go test suite with the race detector.
test-race:
    go test -race ./...

# Run Go static analysis.
vet:
    go vet ./...

# Run the complete platform-neutral repository validation.
check: justfile-check workflow-check proto-core test-race vet build
    just harness test

# Run the platform-neutral checks and both native client test suites.
check-all: check
    just mac check
    just android check

# Verify every Just module is formatted and parseable.
justfile-check:
    just --fmt --check
    just --justfile just/mac.just --fmt --check
    just --justfile just/android.just --fmt --check
    just --justfile just/daemon.just --fmt --check
    just --justfile just/gateway.just --fmt --check
    just --justfile just/harness.just --fmt --check
    just --justfile just/site.just --fmt --check
    just --justfile just/release.just --fmt --check

# Verify that workflow shell execution is centralized through Just.
workflow-check:
    just release workflow-check

# Install the local pre-commit hooks.
hooks:
    command -v pre-commit >/dev/null || { echo "pre-commit is required; install it with: brew install pre-commit" >&2; exit 1; }
    pre-commit install --install-hooks

# Run every pre-commit hook against the repository.
pre-commit:
    command -v pre-commit >/dev/null || { echo "pre-commit is required; install it with: brew install pre-commit" >&2; exit 1; }
    pre-commit run --all-files

# Install the Dieter CLI. PREFIX defaults to /usr/local.
install prefix="/usr/local" destdir="":
    just daemon install "{{ prefix }}" "{{ destdir }}"

# Remove only repository-level generated binaries.
[confirm]
clean:
    rm -f bin/dieter bin/dieter-gateway dieter dieter-gateway coverage.out
