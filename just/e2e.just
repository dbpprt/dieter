set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

export ANDROID_HOME := env_var_or_default("ANDROID_HOME", env_var_or_default("ANDROID_SDK_ROOT", home_directory() / "Library/Android/sdk"))
export JAVA_HOME := env_var_or_default("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home")

# List native test commands. Use just e2e run --help for execution options.
default:
    @just --justfile just/e2e.just --list

# Validate every case without requiring a device or native toolchain.
lint:
    go run ./tools/e2e lint

# Portable validation used by local checks, CI, and release gates; no devices.
check: lint
    go run ./tools/e2e prepare --platform ios --device iphone >/dev/null
    go run ./tools/e2e prepare --platform ios --device ipad >/dev/null

# List cases, optionally filtered by platform, suite, or exact ID.
[positional-arguments]
list *args:
    go run ./tools/e2e list "$@"

# Explain the resolved native execution plan without starting a device.
[positional-arguments]
plan *args:
    go run ./tools/e2e plan "$@"

# Prepare the versioned JSON contract, for all native platforms.
[positional-arguments]
prepare *args:
    go run ./tools/e2e prepare "$@"

# Execute Android, Mac or iOS cases; missing/skipped required tests fail qualification.
[positional-arguments]
run *args:
    go run ./tools/e2e run "$@"

# Require every matrix device job for the stable native CI gate.
ci-result:
    test "${NATIVE_DEVICE_RESULT:-missing}" = success
