# Dieter command index. Go, docs and site work need only the tools from
# mise.toml; native builds, device tests and releases run through Fastlane
# (`just pipeline …`, see fastlane/README.md). Use `mise exec -- just …` when
# mise is not activated in your shell.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

export FASTLANE_OPT_OUT_USAGE := "true"
export FASTLANE_SKIP_UPDATE_CHECK := "true"
export FASTLANE_HIDE_CHANGELOG := "true"
export LANG := "en_US.UTF-8"
export LC_ALL := "en_US.UTF-8"

go_packages := "./cmd/... ./internal/... ./tools/..."

alias proto := generate

# List the recipes.
default:
    @just --list

# Install the pinned tools, the Fastlane gems and the harness dependencies.
setup:
    mise install --locked
    bundle install
    npm --prefix internal/harness/runtime ci

# Build the daemon/CLI and the gateway into bin/.
build:
    go build -o bin/ ./cmd/...

# Go unit and component tests (default build tags).
test *args:
    go test -timeout 15m -shuffle=on {{ go_packages }} "$@"

# Go end-to-end tests (`-tags e2e`) of the packages that have them.
test-e2e *args:
    go test -tags e2e -timeout 20m $(grep -rl --include='*_test.go' '^//go:build e2e' cmd internal tools | xargs -n1 dirname | sort -u | sed 's|^|./|') "$@"

# Selection flags for lint, fmt-check and secrets: --staged (the index),
# --base REF (a branch since its merge base) or --all; default: your changes.

# Lint formatting, secrets and workflows of the selection, plus Go (golangci-lint,
# tidy, identity drift) unless --staged (the pre-commit hook stays fast).
lint *args: lint-workflows
    ruby fastlane/helpers/format.rb "$@"
    just secrets "$@"
    apps/apple/mac/scripts/check-api-boundary.sh
    if [[ " $* " != *" --staged "* ]]; then just lint-go; fi

# Gitleaks over the same selection as lint (redacted findings).
secrets *args:
    if [[ " $* " == *" --staged "* ]]; then gitleaks git --pre-commit --staged --redact --no-banner; \
    elif [[ "${1:-}" == --base ]]; then gitleaks git --log-opts="$(git merge-base "$2" HEAD)..HEAD" --redact --no-banner; \
    elif [[ " $* " == *" --all "* ]]; then gitleaks git --redact --no-banner; \
    else gitleaks git --pre-commit --redact --no-banner; fi

# Check formatting only (same selection flags as lint).
fmt-check *args:
    ruby fastlane/helpers/format.rb "$@"

# Format working files (changed files; --all for every file). Never stages.
fmt *args:
    ruby fastlane/helpers/format.rb --write "$@"

# golangci-lint, go mod tidy drift and generated identity drift.
lint-go:
    golangci-lint run {{ go_packages }}
    go mod tidy -diff
    go run ./tools/identity -check

# actionlint plus a check that every third-party action is pinned to a full SHA.
lint-workflows:
    actionlint
    ! grep -rnE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*[^.[:space:]][^@]*@([^0-9a-f]|[0-9a-f]{0,39}([^0-9a-f]|$))' .github/workflows .github/actions 2>/dev/null

# Regenerate identity constants and schema code (Go everywhere, Swift on macOS);
# CI regenerates and fails on any diff. Kotlin generates from api/proto at build time.
generate:
    #!/usr/bin/env bash
    set -euo pipefail
    go run ./tools/identity
    buf lint api
    # Generated trees are owned by buf: clear them so renamed schemas leave no stale files.
    rm -rf internal/gen/dieter
    buf generate --template api/buf.gen.go.yaml
    buf generate --template api/buf.gen.connect.yaml
    if [[ "$(uname -s)" == Darwin ]]; then
        # Swift plugins come from DieterKit's resolved packages, so generated
        # code always matches the SwiftProtobuf/GRPC runtime the apps link.
        plugins="${DIETER_SWIFT_PROTOC_PLUGINS:-$PWD/tmp/swift-protoc-plugins}"
        for plugin in protoc-gen-swift protoc-gen-grpc-swift-2; do
            swift build --package-path apps/apple/DieterKit --scratch-path "$plugins" \
                --only-use-versions-from-resolved-file -c release --product "$plugin" >/dev/null
        done
        bin="$(swift build --package-path apps/apple/DieterKit --scratch-path "$plugins" -c release --show-bin-path)"
        rm -rf apps/apple/DieterKit/Sources/{DieterAPI,DieterAPIGRPC,DieterClientAPI}/Generated
        PATH="$bin:$PATH" buf generate --template api/buf.gen.swift.yaml
        PATH="$bin:$PATH" buf generate --template api/buf.gen.swift-client.yaml
    else
        echo "Skipping Swift bindings: they are generated on macOS." >&2
    fi

# Plan and run fast checks for the files you changed (--base REF, --dry-run, --native).
check-changed *args:
    ruby fastlane/helpers/changes.rb "$@"

# Run Gradle in the Kotlin build, e.g. `just kotlin :core:runtime:jvmTest`.
kotlin *args:
    apps/kotlin/gradlew -p apps/kotlin --console=plain "$@"

# DieterCore.xcframework for the Apple apps (slices:macos,ios-simulator,ios-device).
framework *args:
    bundle exec fastlane framework "$@"

# Platform lanes, e.g. `just mac build`, `just mac test_unit`, `just mac run`,
# `just ios build`, `just android test_unit` (see fastlane/README.md).
mac *args:
    bundle exec fastlane mac "$@"

ios *args:
    bundle exec fastlane ios "$@"

android *args:
    bundle exec fastlane android "$@"

# Maestro device flows: just e2e android|ios|mac [tags:smoke|full] [flows:a,b] [profile:NAME]
e2e platform *args:
    shift; bundle exec fastlane {{ platform }} e2e "$@"

# Website (site/): live preview with drafts.
site-serve host="127.0.0.1" port="1313":
    HUGO_ENVIRONMENT=development TZ=Europe/Berlin hugo server --source site --buildDrafts --bind "{{ host }}" --port "{{ port }}"

# Production website build (SITE_BASE_URL optional).
site-build:
    HUGO_ENVIRONMENT=production TZ=Europe/Berlin hugo --source site --minify --gc ${SITE_BASE_URL:+--baseURL "${SITE_BASE_URL%/}/"}

# Build and check documentation links, anchors and assets.
site-check: site-build
    python3 site/tools/check_docs.py

# Install the pre-commit hook (`just lint --staged`) for this clone.
hooks:
    current="$(git config --local --get core.hooksPath || true)"; \
    if [[ -n "$current" && "$current" != .githooks ]]; then echo "core.hooksPath is $current; keeping it" >&2; exit 1; fi; \
    git config --local core.hooksPath .githooks && echo "Installed .githooks/pre-commit"

# Fastlane lanes: just pipeline <lane> | <android|ios|mac> <lane> [key:value…]
pipeline *args:
    bundle exec fastlane "$@"

alias app := pipeline

# Unit tests of the Fastlane helpers (leases, journals, filters, versions, flows).
pipeline-test:
    bundle exec ruby -Ifastlane/test fastlane/test/helpers_test.rb
