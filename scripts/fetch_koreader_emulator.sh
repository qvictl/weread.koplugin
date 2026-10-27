#!/usr/bin/env bash
# Fetches the KOReader runtime used by the emulator scenarios.
#
# Preferred: the qvictl/koreader fork's rolling emulator build (release tag
# "nightly", asset koreader-emulator-x86_64-latest.tar.xz) - the KOReader the
# owner's Kindle runs. Until that asset exists (or if it cannot even start the
# plugin), fall back to the official KOReader linux x86_64 release pinned
# below. The switch is automatic; KOREADER_EMULATOR_SOURCE=fork|official|auto
# (default auto) forces one side.
#
#   bash scripts/fetch_koreader_emulator.sh <dest-dir>
#
# Prints (and appends to $GITHUB_OUTPUT when set):
#   runtime=<dir with reader.lua>  source=fork|official  label=<text>
# Needs gh (GH_TOKEN) for release downloads.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${1:?usage: fetch_koreader_emulator.sh <dest-dir>}"
mode="${KOREADER_EMULATOR_SOURCE:-auto}"

readonly FORK_REPO="qvictl/koreader"
readonly FORK_TAG="nightly"
readonly FORK_ASSET="koreader-emulator-x86_64-latest.tar.xz"
readonly OFFICIAL_REPO="koreader/koreader"
readonly OFFICIAL_TAG="v2026.07.1"
readonly OFFICIAL_ASSET="koreader-linux-x86_64-${OFFICIAL_TAG}.tar.xz"

mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"

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

emit() {
    echo "runtime=$1"
    echo "source=$2"
    echo "label=$3"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "runtime=$1"
            echo "source=$2"
            echo "label=$3"
        } >> "$GITHUB_OUTPUT"
    fi
}

try_fork() {
    local dir="$dest/fork"
    rm -rf "$dir" && mkdir -p "$dir"
    if ! gh release download "$FORK_TAG" -R "$FORK_REPO" -p "$FORK_ASSET" -D "$dir" 2>"$dir/download.log"; then
        echo "fork emulator asset not available: $(tr '\n' ' ' < "$dir/download.log")" >&2
        return 1
    fi
    mkdir -p "$dir/extract"
    tar -xf "$dir/$FORK_ASSET" -C "$dir/extract"
    local runtime
    if ! runtime="$(find_runtime "$dir/extract")"; then
        echo "fork emulator asset has no runnable KOReader (reader.lua + luajit + frontend)" >&2
        return 1
    fi
    local updated
    updated="$(gh release view "$FORK_TAG" -R "$FORK_REPO" --json assets \
        --jq ".assets[] | select(.name == \"$FORK_ASSET\") | .updatedAt" 2>/dev/null || true)"
    local rev
    rev="$(cat "$runtime/git-rev" 2>/dev/null || echo unknown)"
    # Probe: the fork build must at least start KOReader and load the plugin.
    if ! python3 "$repo_dir/scripts/run_emulator_scenarios.py" --koreader "$runtime" \
            --out "$dir/probe" --scenario 01 >"$dir/probe.log" 2>&1; then
        echo "fork emulator failed the plugin-load probe; see probe log below" >&2
        tail -n 40 "$dir/probe.log" >&2 || true
        return 1
    fi
    FORK_RUNTIME="$runtime"
    FORK_LABEL="qvictl/koreader $FORK_TAG ($rev, asset updated ${updated:-?})"
}

use_official() {
    local dir="$dest/official"
    if [[ ! -f "$dir/$OFFICIAL_ASSET" ]]; then
        rm -rf "$dir" && mkdir -p "$dir"
        gh release download "$OFFICIAL_TAG" -R "$OFFICIAL_REPO" -p "$OFFICIAL_ASSET" -D "$dir"
    fi
    rm -rf "$dir/extract" && mkdir -p "$dir/extract"
    tar -xf "$dir/$OFFICIAL_ASSET" -C "$dir/extract"
    local runtime
    runtime="$(find_runtime "$dir/extract")"
    emit "$runtime" official "koreader/koreader $OFFICIAL_TAG (official linux x86_64; fork emulator build not used)"
}

case "$mode" in
    fork)
        try_fork || { echo "error: KOREADER_EMULATOR_SOURCE=fork but the fork build is unusable" >&2; exit 1; }
        emit "$FORK_RUNTIME" fork "$FORK_LABEL"
        ;;
    official)
        use_official
        ;;
    auto)
        if try_fork; then
            emit "$FORK_RUNTIME" fork "$FORK_LABEL"
        else
            if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
                echo "::notice::Using the official KOReader $OFFICIAL_TAG build: the $FORK_REPO '$FORK_TAG' emulator asset is not available or not usable yet."
            fi
            use_official
        fi
        ;;
    *)
        echo "error: KOREADER_EMULATOR_SOURCE must be auto, fork or official" >&2
        exit 2
        ;;
esac
