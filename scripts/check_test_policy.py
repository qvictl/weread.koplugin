#!/usr/bin/env python3
"""PR test policy: Lua code changes must come with test changes.

Fails when a PR changes Lua code under weread/, integrations/ or main.lua
without touching spec/ (unit specs, KOReader specs or emulator scenarios).
A user-visible feature or fix (PR title `feat...` / `fix...`, the repo's
conventional-commit style) must add or update at least one emulator
scenario under spec/emulator/scenarios/. Exempting labels:

- no-tests-needed  maintainer decision: docs, comments or log wording only
- upstream-sync    automated merge of finlater/main (reviewed upstream)

    python3 scripts/check_test_policy.py --base origin/main --head HEAD \
        --labels "no-tests-needed,foo" --title "fix(x): ..." [--summary out.md]
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
SCENARIOS = re.compile(r"^spec/emulator/scenarios/.+\.lua$")
USER_VISIBLE_TITLE = re.compile(r"^\s*(feat|fix)\b", re.IGNORECASE)
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
    parser.add_argument("--title", default="", help="PR title (feat/fix require an emulator scenario change)")
    parser.add_argument("--summary", help="write a Markdown summary here")
    args = parser.parse_args()
    labels = {label.strip() for label in args.labels.split(",") if label.strip()}
    files = changed_files(args.base, args.head)
    code = [name for name in files if CODE.match(name)]
    tests = [name for name in files if TESTS.match(name)]
    scenarios = [name for name in files if SCENARIOS.match(name)]
    user_visible = bool(USER_VISIBLE_TITLE.match(args.title or ""))
    exempt = sorted(labels.intersection(EXEMPT_LABELS))
    if not code:
        verdict, ok = "No Lua code under `main.lua`, `weread/` or `integrations/` changed.", True
    elif exempt:
        verdict, ok = (f"Lua code changed; test requirements waived by label `{exempt[0]}`.", True)
    elif not tests:
        verdict, ok = ("Lua code changed without any change under `spec/`. Add or update unit specs "
                       "(`spec/*_spec.lua`) and an emulator scenario (`spec/emulator/scenarios/`), "
                       "or ask a maintainer for the `no-tests-needed` label (docs, comments or log wording only).",
                       False)
    elif user_visible and not scenarios:
        verdict, ok = ("This is a user-visible feature/fix (PR title starts with `feat`/`fix`) but no emulator "
                       "scenario under `spec/emulator/scenarios/` was added or updated.", False)
    else:
        verdict, ok = (f"Lua code changed ({len(code)} files) together with {len(tests)} test file(s)"
                       + (f", including {len(scenarios)} emulator scenario(s)." if scenarios else "."), True)
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
