#!/usr/bin/env bash
# Sensitive-information scan (CI and pre-commit). Needs a PCRE2-enabled rg:
# a ripgrep without PCRE2 exits 2 on -P, which must fail the scan instead of
# being mistaken for "nothing found".
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! rg --pcre2-version >/dev/null 2>&1; then
    echo "error: ripgrep lacks PCRE2 support; install a PCRE2-enabled rg" >&2
    exit 1
fi

found=0
scan() {
    local description="$1"
    local pattern="$2"
    local status=0
    rg -n -P "$pattern" . \
        --hidden \
        --glob '!.git/**' \
        --glob '!cache/**' \
        --glob '!coverage/**' \
        --glob '!*.epub' || status=$?
    case "$status" in
        0) echo "::error::$description"; found=1 ;;
        1) ;;
        *) echo "error: ripgrep failed (status $status) for: $description" >&2; exit 1 ;;
    esac
}

scan "Possible real WeRead API key. Remove API keys before committing." 'wrk-(?!x{8,})[A-Za-z0-9_-]{12,}'
scan "Possible real WeRead cookie value. Remove cookies before committing." '(wr_skey|wr_rt|wr_vid|ptcz)=((?!XXX)[^;[:space:]'\''"]{8,})'
scan "Possible real x-wrpa header. Remove anti-abuse headers before committing." 'x-wrpa-[0-9]+:\s*((?!\.\.\.)[A-Za-z0-9+/=_-]{12,})'
scan "Possible thirdwx value. Remove account/session data before committing." 'thirdwx[=:]\s*[A-Za-z0-9_-]{8,}'

if (( found == 0 )); then
    echo "No sensitive values found."
fi
exit "$found"
