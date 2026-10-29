#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

lua_bin="${LUAJIT_BIN:-luajit}"
if ! command -v "$lua_bin" >/dev/null 2>&1 && [[ ! -x "$lua_bin" ]]; then
    echo "error: LuaJIT not found; install luajit or set LUAJIT_BIN" >&2
    exit 1
fi

spec_files=(spec/*_spec.lua)
if (( $# )); then
    if [[ $# != 2 || $1 != --manifest ]]; then
        echo "usage: $0 [--manifest test-selection.json]" >&2
        exit 2
    fi
    selection="$(python3 scripts/select_lua_tests.py --manifest "$2" --list)"
    spec_files=()
    while IFS= read -r selected_spec; do
        if [[ -n "$selected_spec" ]]; then spec_files+=("$selected_spec"); fi
    done <<< "$selection"
fi

spec_count=0
for spec_file in "${spec_files[@]+"${spec_files[@]}"}"; do
    echo "==> $spec_file"
    "$lua_bin" "$spec_file"
    spec_count=$((spec_count + 1))
done

echo "$spec_count selected Lua specs passed (no manifest: full suite)."
