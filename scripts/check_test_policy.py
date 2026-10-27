#!/usr/bin/env python3
"""PR test policy: Lua code changes must come with test changes.

Fails when a PR changes Lua code under weread/, integrations/ or main.lua
without touching spec/ (unit specs, KOReader specs or emulator scenarios),
unless an exempting label is present:

- no-tests-needed  maintainer decision (refactor, logging, comments, ...)
- upstream-sync    automated merge of finlater/main (reviewed upstream)

    python3 scripts/check_test_policy.py --base origin/main --head HEAD \
        --labels "no-tests-needed,foo" [--summary out.md]
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
CODE = re.compile(r"^(main\.lua|weread/.+\.lua|integrations/.+\.lua)$")
TESTS = re.compile(r"^spec/")
EXEMPT_LABELS = ("no-tests-needed", "upstream-sync")


def changed_files(base: str, head: str) -> list:
    merge_base = subprocess.check_output(["git", "merge-base", base, head], cwd=REPO, text=True).strip()
    out = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", merge_base, head],
                                  cwd=REPO, text=True)
    return [line for line in out.splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--labels", default="", help="comma-separated PR labels")
    parser.add_argument("--summary", help="write a Markdown summary here")
    args = parser.parse_args()
    labels = {label.strip() for label in args.labels.split(",") if label.strip()}
    files = changed_files(args.base, args.head)
    code = [name for name in files if CODE.match(name)]
    tests = [name for name in files if TESTS.match(name)]
    exempt = sorted(labels.intersection(EXEMPT_LABELS))
    if not code:
        verdict, ok = "No Lua code under `main.lua`, `weread/` or `integrations/` changed.", True
    elif tests:
        verdict, ok = f"Lua code changed ({len(code)} files) together with {len(tests)} test file(s).", True
    elif exempt:
        verdict, ok = (f"Lua code changed without test changes; exempted by label `{exempt[0]}`.", True)
    else:
        verdict, ok = ("Lua code changed without any change under `spec/`. Add or update unit specs "
                       "(`spec/*_spec.lua`) and/or emulator scenarios (`spec/emulator/scenarios/`), "
                       "or ask a maintainer for the `no-tests-needed` label.", False)
    lines = [f"### Test policy: {'✅ pass' if ok else '❌ fail'}", "", verdict, ""]
    if code:
        lines += ["<details><summary>Changed Lua code</summary>", ""] + [f"- `{name}`" for name in code] + ["", "</details>"]
    if tests:
        lines += ["<details><summary>Changed tests</summary>", ""] + [f"- `{name}`" for name in tests] + ["", "</details>"]
    text = "\n".join(lines) + "\n"
    if args.summary:
        Path(args.summary).write_text(text, encoding="utf-8")
    print(text)
    if not ok:
        print("::error::" + verdict)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
