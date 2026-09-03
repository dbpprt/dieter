set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

binary := "bin/dieter-gateway"
target := "./cmd/dieter-gateway"

# List the gateway commands.
default:
    @just --justfile just/gateway.just --list

# Verify gateway build and container dependencies.
doctor:
    command -v go
    go version
    command -v docker >/dev/null || echo "Docker is optional unless building the gateway image."

# Build the gateway binary.
build:
    mkdir -p bin
    go build -trimpath -o "{{ binary }}" "{{ target }}"

# Test every Dieter package in the gateway command's dependency graph.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    packages=()
    while IFS= read -r package; do packages+=("$package"); done < <(
        go list -deps "{{ target }}" | rg '^github[.]com/dbpprt/dieter/'
    )
    go test "${packages[@]}"

# Start the gateway in the foreground with its configured environment.
run:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v lsof >/dev/null && lsof -nP -iTCP:4243 -sTCP:LISTEN | rg -q .; then
        echo "Port 4243 already has a listener; refusing to start a second default gateway." >&2
        exit 1
    fi
    go run "{{ target }}"

# Start the disposable gateway/daemon harness used by native end-to-end tests.
isolated addr="127.0.0.1:14243":
    go run ./scripts/isolated-gateway --addr "{{ addr }}"

# Cross-compile and archive one release target using GOOS, GOARCH, and ASSET.
package-release:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GOOS:?GOOS is required}"
    : "${GOARCH:?GOARCH is required}"
    : "${ASSET:?ASSET is required}"
    [[ "$ASSET" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe ASSET: $ASSET" >&2; exit 1; }
    package="stage/$ASSET"
    archive="dist/$ASSET.tar.gz"
    [[ ! -e "$package" && ! -e "$archive" ]] || { echo "Release output already exists: $ASSET" >&2; exit 1; }
    mkdir -p "$package" dist
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
        -o "$package/dieter-gateway" "{{ target }}"
    cp LICENSE "$package/LICENSE"
    tar -C stage -czf "$archive" "$ASSET"
    echo "$archive"

# Build a local gateway container image.
image tag="dieter-gateway:local":
    docker build --file Dockerfile.gateway --tag "{{ tag }}" .

# Build and publish the configured multi-platform gateway image.
[confirm]
image-publish:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Image publishing is CI-only." >&2; exit 1; }
    : "${GATEWAY_IMAGE_TAGS:?GATEWAY_IMAGE_TAGS is required}"
    arguments=(buildx build --file Dockerfile.gateway --platform linux/amd64,linux/arm64 --push)
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && arguments+=(--tag "$tag")
    done <<<"$GATEWAY_IMAGE_TAGS"
    while IFS= read -r label; do
        [[ -n "$label" ]] && arguments+=(--label "$label")
    done <<<"${GATEWAY_IMAGE_LABELS:-}"
    docker "${arguments[@]}" .

# Remove only gateway build and staged release outputs.
[confirm]
clean:
    rm -rf "{{ binary }}" dist/dieter-gateway-*.tar.gz stage/dieter-gateway-*
