set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

runtime := "internal/harness/runtime"

# List the harness runtime commands.
default:
    @just --justfile just/harness.just --list

# Verify the Node.js toolchain used by the harness runtime.
doctor:
    command -v node
    command -v npm
    node --version
    npm --version

# Install the pinned harness runtime dependencies.
install:
    npm --prefix "{{ runtime }}" ci

# Run the harness runtime test suite.
test:
    npm --prefix "{{ runtime }}" test
