#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep (rg) is required for the Lua namespace check" >&2
    exit 1
fi

# The legacy-key pattern needs PCRE2. A ripgrep built without it exits with
# status 2, which a plain `if rg ...` would silently treat as "no match".
if ! rg --pcre2-version >/dev/null 2>&1; then
    echo "error: ripgrep lacks PCRE2 support; install a PCRE2-enabled rg (e.g. the official release binary)" >&2
    exit 1
fi

# Runs rg and maps its status: 0 match -> "found", 1 no match -> "clean",
# anything else is an error that must fail the check instead of passing it.
rg_check() {
    local status=0
    rg "$@" || status=$?
    if (( status > 1 )); then
        echo "error: ripgrep failed (status $status): rg $*" >&2
        exit 1
    fi
    return "$status"
}

failed=0

for legacy_dir in lib ui; do
    if [[ -d "$legacy_dir" ]]; then
        echo "error: project modules must not be added to root-level $legacy_dir/" >&2
        failed=1
    fi
done

legacy_pattern='require[[:space:]]*\([[:space:]]*["'\''](lib|ui)\.|package\.(loaded|preload)[[:space:]]*\[[[:space:]]*["'\''](lib|ui)\.'
if rg_check -n --pcre2 "$legacy_pattern" --glob '*.lua' main.lua _meta.lua weread; then
    echo "error: use weread.lib.* or weread.ui.* for project-owned Lua modules" >&2
    failed=1
fi

if rg_check -n 'require[[:space:]]*\([[:space:]]*["'\'']logger["'\'']' \
    --glob '*.lua' \
    --glob '!weread/lib/logger.lua' \
    main.lua _meta.lua weread; then
    echo "error: use weread.lib.logger so project log messages receive a consistent prefix" >&2
    failed=1
fi

unexpected_modules="$(
    find weread -type f -name '*.lua' \
        ! -path 'weread/lib/*' \
        ! -path 'weread/ui/*' \
        -print
)"
if [[ -n "$unexpected_modules" ]]; then
    echo "error: Lua modules below weread/ must be classified under lib/ or ui/:" >&2
    echo "$unexpected_modules" >&2
    failed=1
fi

exit "$failed"
