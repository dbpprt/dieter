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
build version="":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bin
    if [[ -n "{{ version }}" ]]; then
        go build -trimpath -ldflags "-X github.com/dbpprt/dieter/internal/buildinfo.ReleaseVersion={{ version }}" -o "{{ binary }}" "{{ target }}"
    else
        go build -trimpath -o "{{ binary }}" "{{ target }}"
    fi

# Test every Dieter package in the gateway command's dependency graph.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    packages=()
    while IFS= read -r package; do packages+=("$package"); done < <(
        go list -deps "{{ target }}" | grep -E '^github[.]com/dbpprt/dieter/'
    )
    go test "${packages[@]}"

# Check known gateway vulnerabilities with the image's pinned Go release.
vulncheck:
    #!/usr/bin/env bash
    set -euo pipefail
    gateway_toolchain="$(sed -n 's/^go /go/p' go.mod)"
    GOTOOLCHAIN="$gateway_toolchain" go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./cmd/dieter-gateway

# Start the gateway in the foreground with its configured environment.
run:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v lsof >/dev/null && lsof -nP -iTCP:4243 -sTCP:LISTEN | grep -q .; then
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
    : "${RELEASE_VERSION:?RELEASE_VERSION is required}"
    [[ "$ASSET" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe ASSET: $ASSET" >&2; exit 1; }
    package="stage/$ASSET"
    archive="dist/$ASSET.tar.gz"
    [[ ! -e "$package" && ! -e "$archive" ]] || { echo "Release output already exists: $ASSET" >&2; exit 1; }
    mkdir -p "$package" dist
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/dbpprt/dieter/internal/buildinfo.ReleaseVersion=$RELEASE_VERSION" \
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
    arguments=(buildx build --file Dockerfile.gateway --platform linux/amd64,linux/arm64 --push
        --build-arg "RELEASE_VERSION=${GATEWAY_RELEASE_VERSION:-main}"
        --build-arg "SOURCE_REVISION=${GITHUB_SHA:-unknown}")
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

# Render public configuration and protected secret files; see --help.
[positional-arguments]
render *args:
    python3 deploy/gateway/scripts/render.py "$@"

# Build, verify, or fetch an immutable gateway deployment bundle.
[positional-arguments]
bundle *args:
    python3 deploy/gateway/scripts/bundle.py "$@"

# Validate deployment settings, secret handling, signatures, and recovery logic.
deployment-test:
    python3 -m unittest discover -s deploy/gateway/tests -p 'test_*.py'

# Exercise the pinned gateway, Caddy, HAProxy and coturn in disposable containers.
deployment-integration:
    python3 deploy/gateway/tests/integration.py

# Probe real bidirectional TURN payloads using short-lived credentials on stdin.
turn-test:
    go run ./scripts/gateway-turn-probe

# Publish the signed image and durable OCI deployment bundle from the same commit.
publish-bundle:
    python3 deploy/gateway/scripts/bundle.py publish

# Install the same checksum-pinned signing and OCI tools used on deployment hosts.
publisher-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 deploy/gateway/scripts/install_tools.py cosign bin/cosign
    python3 deploy/gateway/scripts/install_tools.py oras bin/oras
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        python3 -c 'from pathlib import Path; import os; Path(os.environ["GITHUB_PATH"]).open("a").write(str(Path("bin").resolve()) + "\n")'
    fi
