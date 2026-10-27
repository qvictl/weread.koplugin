#!/usr/bin/env python3
"""LuaCov helpers for CI: merge per-spec stats, compute diff coverage.

    python3 scripts/coverage_tools.py merge coverage/parts coverage/luacov.stats.out
    python3 scripts/coverage_tools.py diff coverage/luacov.report.out --base origin/main \
        --threshold 70 --summary coverage/diff.md --json coverage/diff.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
TRACKED = re.compile(r"^(main\.lua|weread/.+\.lua|integrations/.+\.lua)$")


def normalize(name: str) -> str:
    name = name.strip()
    if name.startswith("@"):
        name = name[1:]
    repo = str(REPO) + "/"
    if name.startswith(repo):
        name = name[len(repo):]
    while name.startswith("./"):
        name = name[2:]
    return name


def load_stats(path: Path) -> dict:
    data: dict = {}
    tokens = path.read_text(encoding="utf-8", errors="replace").split("\n")
    i = 0
    while i + 1 < len(tokens):
        header = tokens[i]
        match = re.match(r"^(\d+):(.*)$", header)
        if not match:
            i += 1
            continue
        count, name = int(match.group(1)), normalize(match.group(2))
        hits = [int(x) for x in tokens[i + 1].split()][:count]
        current = data.setdefault(name, [0] * count)
        if len(current) < count:
            current.extend([0] * (count - len(current)))
        for line, value in enumerate(hits):
            current[line] += value
        i += 2
    return data


def merge(parts: Path, out: Path) -> None:
    merged: dict = {}
    for stats in sorted(parts.glob("*.stats.out")):
        for name, hits in load_stats(stats).items():
            current = merged.setdefault(name, [0] * len(hits))
            if len(current) < len(hits):
                current.extend([0] * (len(hits) - len(current)))
            for line, value in enumerate(hits):
                current[line] += value
    with out.open("w", encoding="utf-8") as handle:
        for name in sorted(merged):
            hits = merged[name]
            handle.write(f"{len(hits)}:{name}\n")
            handle.write("".join(f"{value} " for value in hits) + "\n")
    print(f"merged {len(merged)} files into {out}")


def parse_report(path: Path) -> dict:
    """luacov.report.out -> {file: {line: hits}} for executable lines only."""
    files: dict = {}
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    i = 0
    current = None
    line_no = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("=" * 20) and i + 2 < len(lines) and lines[i + 2].startswith("=" * 20):
            name = normalize(lines[i + 1])
            if name == "Summary":
                break
            current = files.setdefault(name, {})
            line_no = 0
            i += 3
            continue
        if current is not None:
            line_no += 1
            # Fixed 9-character hit column, then a space, then the source.
            token = line[:9].strip()
            if token:
                current[line_no] = 0 if token.startswith("*") else int(token)
        i += 1
    return files


def changed_lines(base: str, head: str) -> dict:
    merge_base = subprocess.check_output(["git", "merge-base", base, head], cwd=REPO, text=True).strip()
    diff = subprocess.check_output(["git", "diff", "-U0", "--no-color", "--diff-filter=AM", merge_base, head, "--",
                                    "main.lua", "weread", "integrations"], cwd=REPO, text=True)
    result: dict = {}
    current = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            name = line[4:]
            name = name[2:] if name.startswith("b/") else name
            current = name if TRACKED.match(name) else None
            if current:
                result.setdefault(current, set())
        elif current and line.startswith("@@"):
            match = re.search(r"\+(\d+)(?:,(\d+))?", line)
            start, count = int(match.group(1)), int(match.group(2) or "1")
            result[current].update(range(start, start + count))
    return {name: lines for name, lines in result.items() if lines}


def ranges(numbers) -> str:
    numbers = sorted(numbers)
    out, start, prev = [], None, None
    for n in numbers:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append(f"{start}" if start == prev else f"{start}-{prev}")
            start = prev = n
    if start is not None:
        out.append(f"{start}" if start == prev else f"{start}-{prev}")
    return ", ".join(out)


def diff_coverage(args) -> int:
    report = parse_report(Path(args.report))
    changes = changed_lines(args.base, args.head)
    rows, total_exec, total_hit = [], 0, 0
    for name in sorted(changes):
        file_cov = report.get(name)
        lines = changes[name]
        if file_cov is None:
            # Never loaded by any spec: every changed code line counts as missed.
            source = (REPO / name).read_text(encoding="utf-8", errors="replace").split("\n")
            executable = {n for n in lines if n - 1 < len(source) and source[n - 1].strip()
                          and not source[n - 1].strip().startswith("--")
                          and source[n - 1].strip() not in ("end", "else", "}", "},", ")", "do", "then")}
            hit = set()
        else:
            executable = {n for n in lines if n in file_cov}
            hit = {n for n in executable if file_cov[n] > 0}
        total_exec += len(executable)
        total_hit += len(hit)
        rows.append(dict(file=name, changed=len(lines), executable=len(executable), covered=len(hit),
                         missed=sorted(executable - hit), loaded=file_cov is not None))
    percent = 100.0 if total_exec == 0 else 100.0 * total_hit / total_exec
    passed = total_exec == 0 or percent >= args.threshold
    md = [f"### Diff coverage of changed Lua lines: {percent:.1f}% ({total_hit}/{total_exec})", "",
          f"Threshold: {args.threshold:.0f}% · base `{args.base}` · unit specs under LuaCov "
          f"(`bash scripts/run_lua_coverage.sh`). {'✅ pass' if passed else '❌ below threshold'}", ""]
    if rows:
        md += ["| File | Changed lines | Executable | Covered | Missed lines |", "| --- | --- | --- | --- | --- |"]
        for row in rows:
            pct = 100.0 if not row["executable"] else 100.0 * row["covered"] / row["executable"]
            note = "" if row["loaded"] else " (not loaded by any spec)"
            md.append(f"| `{row['file']}`{note} | {row['changed']} | {row['executable']} | "
                      f"{row['covered']} ({pct:.0f}%) | {ranges(row['missed']) or '-'} |")
    else:
        md.append("No Lua changes under `main.lua`, `weread/` or `integrations/`.")
    text = "\n".join(md) + "\n"
    if args.summary:
        Path(args.summary).write_text(text, encoding="utf-8")
    if args.json:
        Path(args.json).write_text(json.dumps(dict(percent=round(percent, 2), covered=total_hit, executable=total_exec,
                                                   threshold=args.threshold, passed=passed, files=rows),
                                              ensure_ascii=False, indent=2), encoding="utf-8")
    print(text)
    return 0 if passed else 1


def total_coverage(args) -> int:
    report = parse_report(Path(args.report))
    executable = sum(len(lines) for name, lines in report.items() if TRACKED.match(name))
    hit = sum(1 for name, lines in report.items() if TRACKED.match(name) for v in lines.values() if v > 0)
    print(f"{100.0 * hit / max(1, executable):.1f}% ({hit}/{executable}) of executable lines in {len(report)} files")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_merge = sub.add_parser("merge")
    p_merge.add_argument("parts", type=Path)
    p_merge.add_argument("out", type=Path)
    p_diff = sub.add_parser("diff")
    p_diff.add_argument("report")
    p_diff.add_argument("--base", required=True)
    p_diff.add_argument("--head", default="HEAD")
    p_diff.add_argument("--threshold", type=float, default=70.0)
    p_diff.add_argument("--summary")
    p_diff.add_argument("--json")
    p_total = sub.add_parser("total")
    p_total.add_argument("report")
    args = parser.parse_args()
    if args.command == "merge":
        merge(args.parts, args.out)
        return 0
    if args.command == "total":
        return total_coverage(args)
    return diff_coverage(args)


if __name__ == "__main__":
    sys.exit(main())
