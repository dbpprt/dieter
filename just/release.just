set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

# List the shared release commands.
default:
    @just --justfile just/release.just --list

# Verify that every GitHub Actions shell step enters through Just.
workflow-check:
    #!/usr/bin/env bash
    set -euo pipefail
    run_lines="$(rg -n '^[[:space:]]+run:' .github/workflows || true)"
    [[ -n "$run_lines" ]] || { echo "No workflow run steps found." >&2; exit 1; }
    unexpected="$(rg -n '^[[:space:]]+run:' .github/workflows | \
        rg -v 'run:[[:space:]]+just([[:space:]]|$)' || true)"
    if [[ -n "$unexpected" ]]; then
        echo "Workflow run steps must be single Just invocations:" >&2
        printf '%s\n' "$unexpected" >&2
        exit 1
    fi
    if command -v actionlint >/dev/null; then actionlint; fi

# Derive the next release version and write GitHub job outputs.
version:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${RUN_NUMBER:?RUN_NUMBER is required}"
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    : "${GITHUB_SHA:?GITHUB_SHA is required}"
    latest="$(git tag --list 'v*' --sort=-version:refname | \
        awk '/^v[0-9]+[.][0-9]+[.][0-9]+$/ { print; exit }')"
    [[ -n "$latest" ]] || latest="v0.0.0"
    IFS=. read -r major minor patch <<<"${latest#v}"
    next_patch="$RUN_NUMBER"
    if (( next_patch <= patch )); then next_patch=$((patch + RUN_NUMBER)); fi
    number="$major.$minor.$next_patch"
    printf 'tag=v%s\nnumber=%s\nandroid_code=%s\n' "$number" "$number" "$RUN_NUMBER" >>"$GITHUB_OUTPUT"
    echo "Releasing v$number from $GITHUB_SHA."

# Select the pinned Xcode version on the GitHub macOS runner.
select-xcode path="/Applications/Xcode_26.3.app/Contents/Developer":
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Xcode selection is CI-only." >&2; exit 1; }
    sudo xcode-select -s "{{ path }}"

# Validate all-or-none Apple signing configuration and write the enabled output.
signing-config:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    configured=0
    missing=0
    for name in CERTIFICATE_BASE64 CERTIFICATE_PASSWORD NOTARY_KEY_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
        if [[ -n "${!name:-}" ]]; then configured=$((configured + 1)); else missing=$((missing + 1)); fi
    done
    if (( configured == 0 )); then
        echo "enabled=false" >>"$GITHUB_OUTPUT"
        echo "Developer ID credentials are not configured; using the ad-hoc-signed artifact."
    elif (( missing != 0 )); then
        echo "Developer ID signing is only partially configured." >&2
        exit 1
    else
        echo "enabled=true" >>"$GITHUB_OUTPUT"
    fi

# Create SHA-256 checksums for every downloaded release artifact.
checksums:
    #!/usr/bin/env bash
    set -euo pipefail
    test -d dist
    find dist -maxdepth 1 -type f ! -name SHA256SUMS -print -quit | rg -q .
    (
        cd dist
        artifacts=()
        while IFS= read -r artifact; do artifacts+=("$artifact"); done < <(
            find . -maxdepth 1 -type f ! -name SHA256SUMS -exec basename {} \; | sort
        )
        if command -v sha256sum >/dev/null; then
            sha256sum -- "${artifacts[@]}" >SHA256SUMS
        else
            shasum -a 256 -- "${artifacts[@]}" >SHA256SUMS
        fi
    )

# Publish the assembled GitHub release.
[confirm]
publish:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Release publishing is CI-only." >&2; exit 1; }
    : "${GH_TOKEN:?GH_TOKEN is required}"
    : "${RELEASE_TAG:?RELEASE_TAG is required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
    : "${GITHUB_SHA:?GITHUB_SHA is required}"
    if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        echo "Release $RELEASE_TAG already exists." >&2
        exit 1
    fi
    gh release create "$RELEASE_TAG" dist/* --repo "$GITHUB_REPOSITORY" \
        --target "$GITHUB_SHA" --title "Dieter $RELEASE_TAG" \
        --notes "Automated signed build from $GITHUB_SHA." --generate-notes

# Keep only the two newest releases in the main repository.
[confirm]
prune:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Release pruning is CI-only." >&2; exit 1; }
    : "${GH_TOKEN:?GH_TOKEN is required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        delete_args=()
        if [[ "$tag" == main-* ]]; then delete_args+=(--cleanup-tag); fi
        gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --yes "${delete_args[@]}"
    done < <(gh release list --repo "$GITHUB_REPOSITORY" --limit 1000 \
        --json tagName,createdAt --jq 'sort_by(.createdAt) | reverse | .[2:] | .[].tagName')

# Publish macOS artifacts to the Homebrew tap and keep its two newest releases.
[confirm]
homebrew:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Homebrew publishing is CI-only." >&2; exit 1; }
    : "${GH_TOKEN:?GH_TOKEN is required}"
    : "${TAP_REPOSITORY:?TAP_REPOSITORY is required}"
    : "${VERSION:?VERSION is required}"
    daemon_asset="dist/dieter-darwin-arm64.tar.gz"
    app_asset="dist/Dieter-macOS-arm64.zip"
    test -f "$daemon_asset"
    test -f "$app_asset"
    daemon_sha256="$(sha256sum "$daemon_asset" | awk '{print $1}')"
    app_sha256="$(sha256sum "$app_asset" | awk '{print $1}')"
    if gh release view "$VERSION" --repo "$TAP_REPOSITORY" >/dev/null 2>&1; then
        gh release upload "$VERSION" "$daemon_asset" "$app_asset" --repo "$TAP_REPOSITORY" --clobber
    else
        gh release create "$VERSION" "$daemon_asset" "$app_asset" --repo "$TAP_REPOSITORY" \
            --title "Dieter $VERSION" \
            --notes "Apple Silicon daemon and macOS app packages for Dieter $VERSION."
    fi
    gh auth setup-git
    [[ ! -e tap ]] || { echo "tap already exists." >&2; exit 1; }
    git clone "https://github.com/$TAP_REPOSITORY.git" tap
    ruby tap/scripts/update_formula.rb "$VERSION" "$daemon_sha256"
    ruby tap/scripts/update_cask.rb "$VERSION" "$app_sha256"
    ruby -e '
        path = "tap/Formula/dieter.rb"
        formula = File.read(path)
        formula.sub!(/^  depends_on "ffmpeg"\n/, "")
        formula.sub!(/^    bin\.install "dieter"$/, "    bin.install \"dieter\", \"dieter-capture\"")
        File.write(path, formula)
    '
    rg -F 'bin.install "dieter", "dieter-capture"' tap/Formula/dieter.rb
    if ! git -C tap diff --quiet -- Formula/dieter.rb Casks/dieter-app.rb; then
        git -C tap config user.name "github-actions[bot]"
        git -C tap config user.email "41898282+github-actions[bot]@users.noreply.github.com"
        git -C tap add Formula/dieter.rb Casks/dieter-app.rb
        git -C tap commit \
            -m "Update Dieter to $VERSION" \
            -m "🌸 Shipped with Kanna — https://kanna.sh" \
            -m $'Co-Authored-By: Kanna <noreply@kanna.sh>\nKanna-Agent: codex/gpt-5.6-sol'
        git -C tap push origin main
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        gh release delete "$tag" --repo "$TAP_REPOSITORY" --cleanup-tag --yes
    done < <(gh release list --repo "$TAP_REPOSITORY" --limit 1000 \
        --json tagName,createdAt --jq 'sort_by(.createdAt) | reverse | .[2:] | .[].tagName')

# Remove only locally assembled shared release metadata.
[confirm]
clean:
    rm -f dist/SHA256SUMS
    rmdir dist stage 2>/dev/null || true
