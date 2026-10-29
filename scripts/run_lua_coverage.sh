#!/usr/bin/env bash
# Runs the selected specs (every top-level spec by default) under LuaCov and
# writes coverage/unit.stats.out + coverage/unit.report.out. Plugin files no
# spec loads are included with 0 hits (whole-plugin scope).
# Each spec writes its own stats file (specs may fork; children must not
# interleave writes into one file); they are merged afterwards.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

lua_bin="${LUAJIT_BIN:-luajit}"
spec_files=(spec/*_spec.lua)
manifest=""
if (( $# )); then
    if [[ $# != 2 || $1 != --manifest ]]; then
        echo "usage: $0 [--manifest test-selection.json]" >&2
        exit 2
    fi
    manifest="$2"
    selection="$(python3 scripts/select_lua_tests.py --manifest "$manifest" --list)"
    manifest_content="$(cat "$manifest")"
    spec_files=()
    if [[ -n "$selection" ]]; then mapfile -t spec_files <<< "$selection"; fi
fi
if ! "$lua_bin" -e 'require("luacov.runner")' >/dev/null 2>&1; then
    echo "error: LuaCov not found for $lua_bin (luarocks install luacov, or set LUA_PATH)" >&2
    exit 1
fi

rm -rf coverage
mkdir -p coverage/parts
if [[ -n "$manifest" ]]; then
    printf '%s\n' "$manifest_content" > coverage/test-selection.json
else
    python3 scripts/select_lua_tests.py --out coverage/test-selection.json
fi

spec_count=0
failed=0
for spec_file in "${spec_files[@]}"; do
    name="$(basename "$spec_file" .lua)"
    stats="coverage/parts/$name.stats.out"
    if ! "$lua_bin" -joff -e "
        local runner = require('luacov.runner')
        local config = dofile('.luacov')
        config.statsfile = '$stats'
        runner.init(config)
    " "$spec_file" > "coverage/parts/$name.log" 2>&1; then
        # Timing budgets and memory-heavy specs may fail with JIT off and
        # line hooks; the regular spec job enforces them. Coverage keeps
        # whatever the spec recorded before it stopped.
        echo "warning: $spec_file failed under coverage (advisory); see coverage/parts/$name.log" >&2
        failed=$((failed + 1))
    fi
    spec_count=$((spec_count + 1))
done

python3 scripts/coverage_tools.py merge --all-files --out coverage/unit.stats.out coverage/parts
python3 scripts/coverage_tools.py report coverage/unit.stats.out coverage/unit.report.out
if python3 -c 'import json; import sys; sys.exit(json.load(open("coverage/test-selection.json"))["mode"] != "full")'; then
    python3 scripts/coverage_tools.py total coverage/unit.report.out
else
    echo "Partial unit coverage: whole-plugin coverage was not measured."
fi
echo "Coverage collected from $spec_count specs ($failed failed under coverage): coverage/unit.report.out"
