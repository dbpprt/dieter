set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
export FASTLANE_OPT_OUT_USAGE := "true"
export FASTLANE_SKIP_UPDATE_CHECK := "true"
export LANG := "en_US.UTF-8"

mod site 'just/site.just'

# One shared pipeline for local work, CI, candidates and release distribution.
[positional-arguments]
pipeline *args:
    bundle exec fastlane "$@"

# App alias uses exactly the same implementation.
[positional-arguments]
app *args:
    bundle exec fastlane "$@"

# List facade commands; use just pipeline lanes for component operations.
default:
    @just --list

doctor:
    just pipeline doctor

# Include uncommitted changes; --base REF includes branch changes.
[positional-arguments]
check-changed *args:
    bundle exec ruby -r ./fastlane/lib/dieter/checks -e 'Dieter::Checks.cli(ARGV)' -- "$@"

# Complete platform-neutral validation.
check:
    just pipeline ci action:check component:portable

# Complete unit/build validation of every component on a Mac development host.
check-all: check
    just pipeline ci action:check component:core
    just pipeline ci action:check component:core-apple
    just pipeline ci action:check component:mac
    just pipeline ci action:check component:ios
    just pipeline ci action:check component:android

# Regenerate authoritative Go and copied schemas, then checked-in Swift clients.
proto-core:
    ./scripts/generate-proto.sh

proto: proto-core
    just pipeline mac local action:proto_generate

build:
    just pipeline component component:daemon operation:build
    just pipeline component component:gateway operation:build

test:
    just pipeline check component:portable operation:go_test packages:./...

vet:
    just pipeline check component:portable operation:go_vet packages:./...

justfile-check:
    just pipeline check component:portable operation:justfile_check

workflow-check:
    just pipeline check component:portable operation:workflow_check

hooks:
    pre-commit install --install-hooks

pre-commit:
    pre-commit run --all-files
