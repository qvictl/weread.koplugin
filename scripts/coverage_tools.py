#!/usr/bin/env python3
"""LuaCov tooling for the coverage policy (.ci/coverage-policy.json).

Scope: the whole plugin = main.lua + weread/**.lua + integrations/**.lua
(spec/, scripts/ and fixtures are never counted). Files no test loads count
with all their executable lines missed (`merge --all-files`).

    # merge per-process stats (unit spec parts, emulator per-PID files)
    coverage_tools.py merge --out coverage/unit.stats.out --all-files coverage/parts
    # line report (needs LuaCov on LUA_PATH and luajit)
    coverage_tools.py report coverage/unit.stats.out coverage/unit.report.out
    # PR gate: diff unit, diff combined, overall ratchet, dated targets
    coverage_tools.py gate --unit coverage/unit.report.out --combined coverage/combined.report.out \
        --base origin/main --labels "a,b" --baseline baseline.json --summary out.md --json out.json
    # main: baseline.json, badge.json and a history line for the coverage branch
    coverage_tools.py baseline --unit ... --combined ... --sha SHA --out-dir DIR
    # quick totals / single diff
    coverage_tools.py total coverage/unit.report.out
    coverage_tools.py diff coverage/unit.report.out --base origin/main --threshold 80
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
POLICY = REPO / ".ci/coverage-policy.json"
TRACKED = re.compile(r"^(main\.lua|weread/.+\.lua|integrations/.+\.lua)$")
EXEMPT_DIFF_LABELS = ("no-tests-needed", "upstream-sync")


# ----------------------------------------------------------------- stats


def normalize(name: str) -> str:
    name = name.strip().replace("\\", "/")
    if name.startswith("@"):
        name = name[1:]
    marker = "weread.koplugin/"
    if marker in name:
        name = name[name.rindex(marker) + len(marker):]
    repo = str(REPO) + "/"
    if name.startswith(repo):
        name = name[len(repo):]
    name = re.sub(r"/+", "/", name)
    while name.startswith("./"):
        name = name[2:]
    if not name.endswith(".lua") and (name == "main" or name.startswith(("weread/", "integrations/"))):
        name += ".lua"
    return name


def load_stats(path: Path) -> dict:
    data: dict = {}
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    i = 0
    while i + 1 < len(lines):
        match = re.match(r"^(\d+):(.*)$", lines[i])
        if not match:
            i += 1
            continue
        count, name = int(match.group(1)), normalize(match.group(2))
        try:
            hits = [int(x) for x in lines[i + 1].split()][:count]
        except ValueError:
            hits = []
        add_hits(data, name, hits, count)
        i += 2
    return data


def add_hits(data: dict, name: str, hits: list, count: int) -> None:
    current = data.setdefault(name, [0] * count)
    if len(current) < count:
        current.extend([0] * (count - len(current)))
    for line, value in enumerate(hits):
        current[line] += value


def tracked_files() -> list:
    out = subprocess.check_output(["git", "ls-files", "main.lua", "weread", "integrations"], cwd=REPO, text=True)
    return [name for name in out.splitlines() if TRACKED.match(name)]


def merge(args) -> int:
    merged: dict = {}
    inputs = []
    for item in args.inputs:
        path = Path(item)
        if path.is_dir():
            inputs += sorted(p for p in path.rglob("*") if p.is_file() and re.search(r"stats.*\.out$", p.name))
        elif path.is_file():
            inputs.append(path)
    for stats in inputs:
        for name, hits in load_stats(stats).items():
            add_hits(merged, name, hits, len(hits))
    merged = {name: hits for name, hits in merged.items() if TRACKED.match(name)}
    if args.all_files:
        for name in tracked_files():
            count = len((REPO / name).read_text(encoding="utf-8", errors="replace").split("\n"))
            add_hits(merged, name, [], count)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as handle:
        for name in sorted(merged):
            hits = merged[name]
            handle.write(f"{len(hits)}:{name}\n")
            handle.write("".join(f"{value} " for value in hits) + "\n")
    print(f"merged {len(inputs)} stats files, {len(merged)} plugin files -> {out}")
    return 0


def report(args) -> int:
    """Runs LuaCov's reporter on a stats file (cwd = repo root)."""
    lua = os.environ.get("LUAJIT_BIN", "luajit")
    stats, out = Path(args.stats).resolve(), Path(args.out).resolve()
    code = f"""
        local runner = require('luacov.runner')
        local config = dofile('.luacov')
        config.statsfile = {json.dumps(str(stats))}
        config.reportfile = {json.dumps(str(out))}
        runner.load_config(config)
        require('luacov.reporter').report()
    """
    subprocess.run([lua, "-e", code], cwd=REPO, check=True)
    print(f"report -> {out}")
    return 0


def parse_report(path: Path) -> dict:
    """luacov.report.out -> {file: {line: hits}} for executable lines only."""
    files: dict = {}
    lines = Path(path).read_text(encoding="utf-8", errors="replace").split("\n")
    i, current, line_no = 0, None, 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("=" * 20) and i + 2 < len(lines) and lines[i + 2].startswith("=" * 20):
            name = normalize(lines[i + 1])
            if name in ("Summary", "Summary.lua"):
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
    return {name: cov for name, cov in files.items() if TRACKED.match(name)}


# ------------------------------------------------------------------ diff


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


def diff_stats(report_cov: dict, changes: dict) -> dict:
    rows, total_exec, total_hit = [], 0, 0
    for name in sorted(changes):
        cov = report_cov.get(name, {})
        executable = {n for n in changes[name] if n in cov}
        hit = {n for n in executable if cov[n] > 0}
        total_exec += len(executable)
        total_hit += len(hit)
        rows.append(dict(file=name, changed=len(changes[name]), executable=len(executable), covered=len(hit),
                         missed=sorted(executable - hit)))
    percent = 100.0 if total_exec == 0 else 100.0 * total_hit / total_exec
    return dict(percent=round(percent, 2), covered=total_hit, executable=total_exec, files=rows)


def overall(report_cov: dict) -> dict:
    executable = sum(len(cov) for cov in report_cov.values())
    hit = sum(1 for cov in report_cov.values() for value in cov.values() if value > 0)
    percent = 0.0 if executable == 0 else 100.0 * hit / executable
    return dict(percent=round(percent, 2), covered=hit, executable=executable, files=len(report_cov))


def diff(args) -> int:
    stats = diff_stats(parse_report(Path(args.report)), changed_lines(args.base, args.head))
    ok = stats["executable"] == 0 or stats["percent"] >= args.threshold
    print(f"diff coverage {stats['percent']:.1f}% ({stats['covered']}/{stats['executable']}), "
          f"threshold {args.threshold}% -> {'pass' if ok else 'FAIL'}")
    for row in stats["files"]:
        if row["missed"]:
            print(f"  {row['file']}: missed {ranges(row['missed'])}")
    return 0 if ok else 1


def total(args) -> int:
    o = overall(parse_report(Path(args.report)))
    print(f"{o['percent']:.2f}% ({o['covered']}/{o['executable']}) of executable lines in {o['files']} plugin files")
    return 0


# ---------------------------------------------------------------- policy


def load_policy() -> dict:
    return json.loads(POLICY.read_text(encoding="utf-8"))


def effective_targets(policy: dict) -> list:
    day_one = policy.get("day_one_baseline", {}).get("combined", 0.0)
    out = []
    for target in policy.get("targets", []):
        minimum = max(float(target["combined_min"]), float(day_one))
        out.append(dict(date=target["date"], configured=float(target["combined_min"]), effective=round(minimum, 2),
                        label=target.get("label", "")))
    return out


def fmt_pct(value) -> str:
    return "n/a" if value is None else f"{value:.2f}%"


def gate(args) -> int:
    policy = load_policy()
    labels = {label.strip() for label in (args.labels or "").split(",") if label.strip()}
    exempt = sorted(labels.intersection(EXEMPT_DIFF_LABELS))
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    unit_cov = parse_report(Path(args.unit))
    combined_cov = parse_report(Path(args.combined)) if args.combined and Path(args.combined).is_file() else None
    changes = changed_lines(args.base, args.head)
    d_unit = diff_stats(unit_cov, changes)
    d_comb = diff_stats(combined_cov, changes) if combined_cov is not None else None
    o_unit = overall(unit_cov)
    o_comb = overall(combined_cov) if combined_cov is not None else None
    baseline = {}
    if args.baseline and Path(args.baseline).is_file():
        baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))
    base_unit = baseline.get("unit", {}).get("percent", policy["day_one_baseline"]["unit"])
    base_comb = baseline.get("combined", {}).get("percent", policy["day_one_baseline"]["combined"])
    base_src = (f"main@{baseline.get('sha', '?')[:8]} ({baseline.get('date', '?')})" if baseline
                else f"day-one baseline ({policy['day_one_baseline']['date']})")
    tol = float(policy.get("ratchet_tolerance_pp", 0.0))
    checks = []  # (name, ok, blocking, detail)

    def add(name, ok, blocking, detail):
        checks.append(dict(name=name, ok=bool(ok), blocking=bool(blocking), detail=detail))

    unit_min = float(policy["diff_unit_min"])
    comb_min = float(policy["diff_combined_min"])
    add(f"Diff coverage, unit specs ≥ {unit_min:.0f}%",
        d_unit["executable"] == 0 or d_unit["percent"] >= unit_min, not exempt,
        f"{d_unit['percent']:.1f}% ({d_unit['covered']}/{d_unit['executable']} changed executable lines)")
    if d_comb is None:
        add(f"Diff coverage, unit + emulator ≥ {comb_min:.0f}%", False, not exempt,
            "emulator coverage unavailable (Integration run missing or failed)")
    else:
        add(f"Diff coverage, unit + emulator ≥ {comb_min:.0f}%",
            d_comb["executable"] == 0 or d_comb["percent"] >= comb_min, not exempt,
            f"{d_comb['percent']:.1f}% ({d_comb['covered']}/{d_comb['executable']})")
    add("Overall unit coverage does not drop (ratchet)", o_unit["percent"] + tol >= base_unit, True,
        f"{fmt_pct(o_unit['percent'])} vs {fmt_pct(base_unit)} on {base_src}")
    if o_comb is not None:
        add("Overall unit + emulator coverage does not drop (ratchet)", o_comb["percent"] + tol >= base_comb, True,
            f"{fmt_pct(o_comb['percent'])} vs {fmt_pct(base_comb)} on {base_src}")
    for target in effective_targets(policy):
        active = today >= dt.date.fromisoformat(target["date"])
        value = o_comb["percent"] if o_comb is not None else None
        ok = value is not None and value >= target["effective"]
        add(f"Target {target['label'] or target['date']}: overall unit + emulator ≥ {target['effective']:.2f}%"
            + ("" if active else f" (report-only until {target['date']})"),
            ok, active, f"{fmt_pct(value)}; configured {target['configured']:.0f}%, "
                        f"effective max(configured, day-one baseline)")

    failed_blocking = [c for c in checks if c["blocking"] and not c["ok"]]
    md = [f"### Coverage: {'✅ pass' if not failed_blocking else '❌ fail'}", ""]
    md += ["| Check | Result | Blocking | Detail |", "| --- | --- | --- | --- |"]
    for c in checks:
        md.append(f"| {c['name']} | {'✅' if c['ok'] else '❌'} | {'yes' if c['blocking'] else 'no'} | {c['detail']} |")
    if exempt:
        md += ["", f"Diff-coverage gates waived by label `{exempt[0]}`; ratchet and active targets still apply."]
    md += ["", f"Overall: unit {fmt_pct(o_unit['percent'])} ({o_unit['covered']}/{o_unit['executable']} lines, "
               f"{o_unit['files']} files)"
           + (f" · unit + emulator {fmt_pct(o_comb['percent'])} ({o_comb['covered']}/{o_comb['executable']})"
              if o_comb else "")]
    history = []
    if args.history and Path(args.history).is_file():
        for line in Path(args.history).read_text(encoding="utf-8").splitlines()[-8:]:
            try:
                history.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    if history:
        trend = " → ".join(f"{h['combined']['percent']:.1f}" for h in history if h.get("combined"))
        md += ["", f"Trend on main (unit + emulator, last {len(history)}): {trend}"]
    rows = d_comb["files"] if d_comb else d_unit["files"]
    unit_rows = {row["file"]: row for row in d_unit["files"]}
    if rows:
        md += ["", "<details><summary>Changed files</summary>", "",
               "| File | Changed | Executable | Unit | Unit + emulator | Missed (unit + emulator) |",
               "| --- | --- | --- | --- | --- | --- |"]
        for row in rows:
            u = unit_rows.get(row["file"], row)
            md.append(f"| `{row['file']}` | {row['changed']} | {row['executable']} | {u['covered']} "
                      f"| {row['covered'] if d_comb else '-'} | {ranges(row['missed']) or '-'} |")
        md += ["", "</details>"]
    else:
        md += ["", "No Lua changes under `main.lua`, `weread/` or `integrations/`."]
    text = "\n".join(md) + "\n"
    if args.summary:
        Path(args.summary).write_text(text, encoding="utf-8")
    if args.json:
        Path(args.json).write_text(json.dumps(dict(
            checks=checks, diff_unit=d_unit, diff_combined=d_comb, overall_unit=o_unit, overall_combined=o_comb,
            baseline_unit=base_unit, baseline_combined=base_comb, passed=not failed_blocking),
            ensure_ascii=False, indent=2), encoding="utf-8")
    print(text)
    return 0 if not failed_blocking else 1


def badge_color(percent: float) -> str:
    for limit, color in ((90, "brightgreen"), (85, "green"), (75, "yellowgreen"), (65, "yellow"), (50, "orange")):
        if percent >= limit:
            return color
    return "red"


def baseline(args) -> int:
    unit = overall(parse_report(Path(args.unit)))
    combined = overall(parse_report(Path(args.combined)))
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    record = dict(sha=args.sha, date=now, unit=unit, combined=combined, run=args.run_url or "")
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "baseline.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    with (out / "history.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")
    (out / "badge.json").write_text(json.dumps(dict(
        schemaVersion=1, label="coverage", message=f"{combined['percent']:.1f}%",
        color=badge_color(combined["percent"]))) + "\n", encoding="utf-8")
    (out / "badge-unit.json").write_text(json.dumps(dict(
        schemaVersion=1, label="unit coverage", message=f"{unit['percent']:.1f}%",
        color=badge_color(unit["percent"]))) + "\n", encoding="utf-8")
    entries = []
    for line in (out / "history.jsonl").read_text(encoding="utf-8").splitlines():
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    policy = load_policy()
    lines = ["# Coverage history (main)", "",
             "Generated by the *Coverage* workflow after every successful `Integration` run on `main`. "
             "Scope: `main.lua`, `weread/`, `integrations/`. Policy: `.ci/coverage-policy.json` on main.", "",
             "Targets (unit + emulator): " + ", ".join(
                 f"≥ {t['effective']:.2f}% from {t['date']}" for t in effective_targets(policy)), "",
             "| Date (UTC) | Commit | Unit | Unit + emulator | Run |", "| --- | --- | --- | --- | --- |"]
    for entry in reversed(entries[-100:]):
        run = f"[run]({entry['run']})" if entry.get("run") else ""
        lines.append(f"| {entry['date']} | `{entry['sha'][:8]}` | {entry['unit']['percent']:.2f}% "
                     f"| {entry['combined']['percent']:.2f}% | {run} |")
    (out / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("merge")
    p.add_argument("--out", required=True)
    p.add_argument("--all-files", action="store_true", help="count untested plugin files as 0%%")
    p.add_argument("inputs", nargs="*")
    p = sub.add_parser("report")
    p.add_argument("stats")
    p.add_argument("out")
    p = sub.add_parser("diff")
    p.add_argument("report")
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--threshold", type=float, default=80.0)
    p = sub.add_parser("total")
    p.add_argument("report")
    p = sub.add_parser("gate")
    p.add_argument("--unit", required=True)
    p.add_argument("--combined")
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--labels", default="")
    p.add_argument("--baseline")
    p.add_argument("--history")
    p.add_argument("--today")
    p.add_argument("--summary")
    p.add_argument("--json")
    p = sub.add_parser("baseline")
    p.add_argument("--unit", required=True)
    p.add_argument("--combined", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--run-url")
    p.add_argument("--out-dir", required=True)
    args = parser.parse_args()
    return dict(merge=merge, report=report, diff=diff, total=total, gate=gate, baseline=baseline)[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
