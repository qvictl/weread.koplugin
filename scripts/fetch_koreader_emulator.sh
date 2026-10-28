#!/usr/bin/env bash
# Fetches the KOReader runtime used by the emulator scenarios.
#
#   KOREADER_EMULATOR_SOURCE=fork|official|auto \
#       bash scripts/fetch_koreader_emulator.sh <dest-dir>
#
# fork      the qvictl/koreader fork's emulator build - the KOReader this
#           plugin is developed for. Release KOREADER_FORK_RELEASE (default
#           the rolling "nightly", asset koreader-emulator-x86_64-latest.tar.xz;
#           a stable tag such as v2026.10.q1 uses
#           koreader-emulator-x86_64-<tag>.tar.xz). The asset is checked
#           against the release's SHA256SUMS and must start KOReader and load
#           the plugin (scenario 01 probe). Any failure exits non-zero: there
#           is no fallback. The build links the system's SDL3, so run it in
#           the koreader/kobase:5.0.0-22.04 image (or install SDL 3); CI's
#           required `integration` check does exactly that.
# official  the official KOReader linux x86_64 release pinned below (needs
#           SDL 2, e.g. libsdl2-2.0-0). CI's `integration-official` check.
# auto      (default; local convenience only, never used by CI) fork if it
#           works on this machine, otherwise official with a warning.
#
# Prints (and appends to $GITHUB_OUTPUT when set):
#   runtime=<dir with reader.lua>  source=fork|official  label=<text>
# plus, for the fork: fork_version, fork_commit, fork_date (build-info.json).
# Under GitHub Actions the KOReader build is also added to the step summary.
# Downloads use curl on the public release URLs (no token needed).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${1:?usage: fetch_koreader_emulator.sh <dest-dir>}"
mode="${KOREADER_EMULATOR_SOURCE:-auto}"

readonly FORK_REPO="qvictl/koreader"
readonly FORK_RELEASE="${KOREADER_FORK_RELEASE:-nightly}"
if [[ "$FORK_RELEASE" == nightly ]]; then
    readonly FORK_ASSET="koreader-emulator-x86_64-latest.tar.xz"
else
    readonly FORK_ASSET="koreader-emulator-x86_64-${FORK_RELEASE}.tar.xz"
fi
readonly OFFICIAL_REPO="koreader/koreader"
# Keep in sync with the `integration-official` job names in
# .github/workflows/integration.yml and docs/testing.md.
readonly OFFICIAL_TAG="v2026.07.1"
readonly OFFICIAL_ASSET="koreader-linux-x86_64-${OFFICIAL_TAG}.tar.xz"

mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"

error() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::error title=KOReader emulator::$*" >&2
    else
        echo "error: $*" >&2
    fi
}

download() { # <repo> <tag> <asset> <file>
    local url="https://github.com/$1/releases/download/$2/$3"
    echo "downloading $url" >&2
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$4" "$url"
}

find_runtime() {
    local root="$1" candidate
    while IFS= read -r candidate; do
        local dir
        dir="$(dirname "$candidate")"
        if [[ -e "$dir/luajit" && -d "$dir/frontend" ]]; then
            echo "$dir"
            return 0
        fi
    done < <(find "$root" -name reader.lua -not -path '*/spec/*' | sort)
    return 1
}

# emit key=value... to stdout and $GITHUB_OUTPUT.
emit() {
    local pair
    for pair in "$@"; do
        echo "$pair"
        if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
            echo "$pair" >> "$GITHUB_OUTPUT"
        fi
    done
}

summary() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
    fi
}

json_field() { # <file> <key>: flat JSON string field, no jq/python needed
    sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$1" | head -n 1
}

# Sets FORK_RUNTIME, FORK_LABEL, FORK_VERSION, FORK_COMMIT, FORK_DATE; prints
# the reason and returns 1 when the fork build is unusable.
try_fork() {
    local dir="$dest/fork"
    rm -rf "$dir" && mkdir -p "$dir"
    if ! download "$FORK_REPO" "$FORK_RELEASE" "$FORK_ASSET" "$dir/$FORK_ASSET"; then
        error "cannot download $FORK_ASSET from the $FORK_REPO '$FORK_RELEASE' release"
        return 1
    fi
    if download "$FORK_REPO" "$FORK_RELEASE" SHA256SUMS "$dir/SHA256SUMS"; then
        local expected actual
        expected="$(awk -v f="$FORK_ASSET" '$2 == f || $2 == "*" f { print $1 }' "$dir/SHA256SUMS")"
        actual="$(sha256sum "$dir/$FORK_ASSET" | cut -d' ' -f1)"
        if [[ -z "$expected" ]]; then
            error "SHA256SUMS of $FORK_REPO '$FORK_RELEASE' does not list $FORK_ASSET"
            return 1
        fi
        if [[ "$expected" != "$actual" ]]; then
            error "$FORK_ASSET checksum mismatch (SHA256SUMS $expected, downloaded $actual); the release may be being republished, re-run later"
            return 1
        fi
    else
        error "cannot download SHA256SUMS from the $FORK_REPO '$FORK_RELEASE' release"
        return 1
    fi
    download "$FORK_REPO" "$FORK_RELEASE" build-info.json "$dir/build-info.json" \
        || echo '{}' > "$dir/build-info.json"
    FORK_VERSION="$(json_field "$dir/build-info.json" version)"
    FORK_COMMIT="$(json_field "$dir/build-info.json" commit)"
    FORK_DATE="$(json_field "$dir/build-info.json" date)"
    mkdir -p "$dir/extract"
    if ! tar -xf "$dir/$FORK_ASSET" -C "$dir/extract"; then
        error "cannot extract $FORK_ASSET"
        return 1
    fi
    local runtime rev
    if ! runtime="$(find_runtime "$dir/extract")"; then
        error "$FORK_ASSET has no runnable KOReader (reader.lua + luajit + frontend)"
        return 1
    fi
    rev="$(cat "$runtime/git-rev" 2>/dev/null || echo unknown)"
    FORK_VERSION="${FORK_VERSION:-$rev}"
    # Probe: the fork build must at least start KOReader and load the plugin.
    if ! python3 "$repo_dir/scripts/run_emulator_scenarios.py" --koreader "$runtime" \
            --out "$dir/probe" --scenario 01 >"$dir/probe.log" 2>&1; then
        error "the $FORK_REPO '$FORK_RELEASE' emulator ($FORK_VERSION) cannot start KOReader with the plugin (scenario 01 probe; needs SDL 3, e.g. the koreader/kobase:5.0.0-22.04 image)"
        echo "--- probe log ---" >&2
        tail -n 40 "$dir/probe.log" >&2 || true
        local crash
        for crash in "$dir"/probe/*/evidence/crash.log; do
            [[ -f "$crash" ]] || continue
            echo "--- $crash ---" >&2
            tail -n 40 "$crash" >&2 || true
        done
        return 1
    fi
    FORK_RUNTIME="$runtime"
    FORK_LABEL="$FORK_REPO $FORK_RELEASE $FORK_VERSION (built ${FORK_DATE:-?})"
}

emit_fork() {
    emit "runtime=$FORK_RUNTIME" "source=fork" "label=$FORK_LABEL" \
        "fork_version=$FORK_VERSION" "fork_commit=$FORK_COMMIT" "fork_date=$FORK_DATE"
    local commit_link="${FORK_COMMIT:-?}"
    if [[ -n "$FORK_COMMIT" ]]; then
        commit_link="[${FORK_COMMIT:0:12}](https://github.com/$FORK_REPO/commit/$FORK_COMMIT)"
    fi
    summary "### KOReader under test: $FORK_REPO fork build" "" \
        "| Release | Build | Commit | Built (asset date) | Asset |" \
        "| --- | --- | --- | --- | --- |" \
        "| [\`$FORK_RELEASE\`](https://github.com/$FORK_REPO/releases/tag/$FORK_RELEASE) | \`$FORK_VERSION\` | $commit_link | ${FORK_DATE:-?} | \`$FORK_ASSET\` |" ""
}

use_official() {
    local dir="$dest/official"
    if [[ ! -f "$dir/$OFFICIAL_ASSET" ]]; then
        rm -rf "$dir" && mkdir -p "$dir"
        if ! download "$OFFICIAL_REPO" "$OFFICIAL_TAG" "$OFFICIAL_ASSET" "$dir/$OFFICIAL_ASSET.part"; then
            error "cannot download $OFFICIAL_ASSET from $OFFICIAL_REPO $OFFICIAL_TAG"
            exit 1
        fi
        mv "$dir/$OFFICIAL_ASSET.part" "$dir/$OFFICIAL_ASSET"
    fi
    rm -rf "$dir/extract" && mkdir -p "$dir/extract"
    tar -xf "$dir/$OFFICIAL_ASSET" -C "$dir/extract"
    local runtime
    if ! runtime="$(find_runtime "$dir/extract")"; then
        error "$OFFICIAL_ASSET has no runnable KOReader (reader.lua + luajit + frontend)"
        exit 1
    fi
    emit "runtime=$runtime" "source=official" "label=$OFFICIAL_REPO $OFFICIAL_TAG (official linux x86_64)"
    summary "### KOReader under test: official $OFFICIAL_REPO $OFFICIAL_TAG" "" \
        "Asset \`$OFFICIAL_ASSET\` of [$OFFICIAL_TAG](https://github.com/$OFFICIAL_REPO/releases/tag/$OFFICIAL_TAG)." ""
}

case "$mode" in
    fork)
        if ! try_fork; then
            error "KOREADER_EMULATOR_SOURCE=fork: the $FORK_REPO '$FORK_RELEASE' emulator build is unusable; not falling back to the official build"
            exit 1
        fi
        emit_fork
        ;;
    official)
        use_official
        ;;
    auto)
        if try_fork; then
            emit_fork
        else
            echo "warning: the $FORK_REPO '$FORK_RELEASE' emulator build is not usable here; using the official KOReader $OFFICIAL_TAG instead (auto mode is for local runs only)" >&2
            use_official
        fi
        ;;
    *)
        error "KOREADER_EMULATOR_SOURCE must be fork, official or auto (got: $mode)"
        exit 2
        ;;
esac
