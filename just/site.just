set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

hugo_version := env_var_or_default("HUGO_VERSION", "0.164.0")

# List the website commands.
default:
    @just --justfile just/site.just --list

# Verify the Hugo toolchain.
doctor:
    command -v hugo
    hugo version

# Serve the website locally with drafts and live reload.
serve host="127.0.0.1" port="1313":
    HUGO_ENVIRONMENT=development TZ=Europe/Berlin hugo server --source landingpage --buildDrafts --bind "{{ host }}" --port "{{ port }}"

# Install the pinned extended Hugo binary on the GitHub Ubuntu runner.
install-ci:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Hugo installation is CI-only." >&2; exit 1; }
    temporary="$(mktemp -d)"
    trap 'rm -rf "$temporary"' EXIT
    curl -fsSL \
        "https://github.com/gohugoio/hugo/releases/download/v{{ hugo_version }}/hugo_extended_{{ hugo_version }}_linux-amd64.tar.gz" \
        -o "$temporary/hugo.tar.gz"
    sudo tar -xzf "$temporary/hugo.tar.gz" -C /usr/local/bin hugo
    hugo version

# Build the production website, optionally with SITE_BASE_URL.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    arguments=(--source landingpage --minify --gc)
    if [[ -n "${SITE_BASE_URL:-}" ]]; then arguments+=(--baseURL "${SITE_BASE_URL%/}/"); fi
    HUGO_ENVIRONMENT=production TZ=Europe/Berlin hugo "${arguments[@]}"

# Remove only the generated website output.
[confirm]
clean:
    rm -rf landingpage/public
