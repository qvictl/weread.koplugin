#!/usr/bin/env python3
"""LuaCov tooling for the coverage policy (.ci/coverage-policy.json).

Scope: the whole plugin = main.lua + weread/**.lua + integrations/**.lua
(spec/, scripts/ and fixtures are never counted). Files no test loads count
with all their executable lines missed (`merge --all-files`).

    # merge per-process stats (unit spec parts, emulator per-PID files)
    coverage_tools.py merge --out coverage/unit.stats.out --all-files coverage/parts
    # line report (needs LuaCov on LUA_PATH and luajit)
    coverage_tools.py report coverage/unit.stats.out coverage/unit.report.out
    # PR unit gate against its own merge-base and nearest unit history record.
    coverage_tools.py gate --mode unit --unit coverage/unit.report.out --base origin/main --history history.jsonl
    # Release combined gate over all unreleased changes since the last genuine
    # combined ancestor. The overall ratchet also includes this candidate.
    coverage_tools.py gate --mode release --unit coverage/unit.report.out --combined coverage/combined.report.out \
        --base origin/main --history history.jsonl --summary out.md --json out.json
    # main: history record (keyed by SHA), baseline.json and badges for the coverage branch
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

REPO = Path(os.environ.get("COVERAGE_REPO", Path(__file__).resolve().parent.parent)).resolve()
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


def hit_column_width(lines: list) -> int:
    """Width of LuaCov's hit column: digits of the report's highest hit count + 1.

    LuaCov's default reporter right-aligns hits in a column one wider than the
    largest count ("*...0" for misses), so the width depends on the run. Miss
    lines and hit lines both start with exactly that many characters; a
    non-executable source line that happens to start with digits only makes a
    longer prefix, so the minimum is the column width.
    """
    widths = [len(m.group(1)) for line in lines
              for m in [re.match(r"^(\*+0|\s+\d+) ", line)] if m]
    return min(widths) if widths else 9


def parse_report(path: Path) -> dict:
    """luacov.report.out -> {file: {line: hits}} for executable lines only."""
    files: dict = {}
    lines = Path(path).read_text(encoding="utf-8", errors="replace").split("\n")
    width = hit_column_width(lines)
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
            # Hit column of `width` characters, then a space, then the source.
            token = line[:width].strip()
            if token:
                current[line_no] = 0 if token.startswith("*") else int(token)
        i += 1
    return {name: cov for name, cov in files.items() if TRACKED.match(name)}


# ------------------------------------------------------------------ diff


def changed_lines(base: str, head: str, direct=False) -> dict:
    merge_base = base if direct else git_merge_base(base, head)
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
    """Dated targets; each may set combined_min, unit_min and module_unit_min.

    Effective overall minimum = max(configured, day-one baseline of the same
    kind), so a target never sits below what main already had on day one.
    module_unit_min = {"pattern": regex, "min": percent} is a per-file floor
    for the unit coverage of every plugin file whose path matches the pattern.
    """
    day_one = policy.get("day_one_baseline", {})
    out = []
    for target in policy.get("targets", []):
        entry = dict(date=target["date"], label=target.get("label", ""))
        for kind in ("combined", "unit"):
            key = f"{kind}_min"
            if key in target:
                configured = float(target[key])
                entry[kind] = dict(configured=configured,
                                   effective=round(max(configured, float(day_one.get(kind, 0.0))), 2))
        floor = target.get("module_unit_min")
        if floor:
            entry["module_unit"] = dict(pattern=floor["pattern"], min=float(floor["min"]))
        out.append(entry)
    return out


def module_floor_misses(report_cov: dict, pattern: str, minimum: float) -> list:
    """Plugin files matching pattern whose unit coverage is below minimum, worst first."""
    misses = []
    for name, cov in report_cov.items():
        if not re.search(pattern, name) or not cov:
            continue
        percent = 100.0 * sum(1 for value in cov.values() if value > 0) / len(cov)
        if percent < minimum:
            misses.append((name, round(percent, 2)))
    return sorted(misses, key=lambda item: (item[1], item[0]))


def target_checks(policy: dict, today, o_unit: dict, o_comb, unit_cov: dict, mode="release") -> list:
    """(name, ok, blocking, detail) per dated target; report-only before its date, blocking from it."""
    checks = []
    for target in effective_targets(policy):
        active = today >= dt.date.fromisoformat(target["date"])
        title = f"Target {target['label'] or target['date']}"
        suffix = "" if active else f" (report-only until {target['date']})"
        if "combined" in target and mode == "release":
            minimum = target["combined"]
            value = o_comb["percent"] if o_comb is not None else None
            checks.append((f"{title}: overall unit + emulator ≥ {minimum['effective']:.2f}%{suffix}",
                           value is not None and value >= minimum["effective"], active,
                           f"{fmt_pct(value)}; configured {minimum['configured']:.0f}%, "
                           f"effective max(configured, day-one baseline)"))
        if "unit" in target:
            minimum = target["unit"]
            value = o_unit["percent"]
            checks.append((f"{title}: overall unit ≥ {minimum['effective']:.2f}%{suffix}",
                           value >= minimum["effective"], active,
                           f"{fmt_pct(value)}; configured {minimum['configured']:.0f}%, "
                           f"effective max(configured, day-one baseline)"))
        if "module_unit" in target:
            floor = target["module_unit"]
            misses = module_floor_misses(unit_cov, floor["pattern"], floor["min"])
            shown = ", ".join(f"`{name}` {percent:.1f}%" for name, percent in misses[:8])
            more = f" (+{len(misses) - 8} more)" if len(misses) > 8 else ""
            checks.append((f"{title}: each file matching `{floor['pattern']}` unit ≥ {floor['min']:.0f}%{suffix}",
                           not misses, active,
                           f"{len(misses)} below: {shown}{more}" if misses else "all files at or above the floor"))
    return checks


def fmt_pct(value) -> str:
    return "n/a" if value is None else f"{value:.2f}%"


def validate_release_checks(checks):
    if not isinstance(checks, dict):
        raise ValueError("release checks must be a run/attempt map")
    for run_id, check in checks.items():
        if (not isinstance(run_id, str) or not run_id.isdigit() or int(run_id) <= 0
                or not isinstance(check, dict) or type(check.get("attempt")) is not int or check["attempt"] <= 0):
            raise ValueError("invalid release run/attempt watermark")
        if "sha" in check or "combined" in check:
            if (not isinstance(check.get("sha"), str) or not re.fullmatch(r"[0-9a-f]{40}", check["sha"])
                    or type(check.get("combined")) not in (int, float) or not 0 <= check["combined"] <= 100):
                raise ValueError("invalid accepted release floor")
    return checks


def merge_release_checks(*maps):
    merged = {}
    for checks in maps:
        for run_id, check in validate_release_checks(checks).items():
            old = merged.get(run_id, {})
            if old.get("sha") and check.get("sha") and old["sha"] != check["sha"]:
                raise ValueError("a release run cannot change its measured source")
            value = dict(old, attempt=max(old.get("attempt", 0), check["attempt"]))
            if "sha" in check:
                value.update(sha=check["sha"], combined=max(old.get("combined", 0), check["combined"]))
            merged[run_id] = value
    return merged


def read_history(path, strict=False) -> list:
    """Keep legacy unit-history tolerance; release history must be complete."""
    records = []
    if not path or not Path(path).is_file():
        if strict:
            raise ValueError("coverage history is missing")
        return records
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            if strict:
                raise ValueError("coverage history contains malformed JSON")
            continue
        if strict:
            valid = (isinstance(record, dict)
                     and isinstance(record.get("sha"), str)
                     and re.fullmatch(r"[0-9a-f]{40}", record["sha"]))
            for metric in ("unit", "combined") if isinstance(record, dict) and "combined" in record else ("unit",):
                value = record.get(metric) if isinstance(record, dict) else None
                percent = value.get("percent") if isinstance(value, dict) else None
                valid = valid and type(percent) in (int, float) and 0 <= percent <= 100
            if not valid:
                raise ValueError("coverage history contains an invalid measurement")
            validate_release_checks(record.get("release_checks", {}))
        if isinstance(record, dict) and record.get("sha"):
            records.append(record)
    if strict and not records:
        raise ValueError("coverage history is empty")
    return records


def git_merge_base(base: str, head: str, cwd=REPO) -> str:
    return subprocess.check_output(["git", "merge-base", base, head], cwd=cwd, text=True).strip()


def git_ancestors(sha: str, cwd=REPO, limit: int = 5000, strict=False) -> list:
    """Walk ancestors; release gates fail closed on unreadable Git history."""
    if not sha:
        return []
    try:
        limit_args = [f"--max-count={limit}"] if limit is not None else []
        out = subprocess.check_output(["git", "rev-list", *limit_args, sha, "--"],
                                      cwd=cwd, text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        if strict:
            raise
        return [sha]
    return out.split() or [sha]


def select_baseline(records: list, base_sha: str, ancestors: list, kind="unit"):
    """Main's coverage record for the commit a PR is measured against.

    Returns (record, match): match is "exact" when base_sha itself has a record,
    "ancestor" when the nearest ancestor of base_sha that has one is used (a main
    commit whose coverage was never published: failed or superseded run), and
    "none" (record None) when no ancestor has one. When a SHA was published more
    than once the last record wins.
    """
    by_sha = {record["sha"]: record for record in records
              if isinstance(record.get(kind), dict) and "percent" in record[kind]}
    for index, sha in enumerate(ancestors or ([base_sha] if base_sha else [])):
        if sha in by_sha:
            return by_sha[sha], ("exact" if index == 0 else "ancestor")
    return None, "none"


def ratchet_checks(policy: dict, o_unit: dict, o_comb, baseline, match: str, base_sha: str) -> dict:
    """Overall-coverage ratchet against main's coverage at the PR's own base commit.

    Comparing with the base the PR is measured against (not main's latest) keeps
    PRs independent: tests another PR merges meanwhile do not raise this PR's bar.
    """
    day_one = policy["day_one_baseline"]
    if baseline:
        base_unit = baseline.get("unit", {}).get("percent", day_one["unit"])
        base_comb = baseline.get("combined", {}).get("percent", day_one["combined"])
        source = f"main@{baseline['sha'][:8]}"
        if match == "ancestor":
            source += f" (nearest ancestor with coverage of base {(base_sha or '?')[:8]})"
        else:
            source += " (this PR's base)"
    else:
        base_unit, base_comb = day_one["unit"], day_one["combined"]
        source = (f"day-one baseline ({day_one['date']}; no coverage recorded for base "
                  f"{(base_sha or '?')[:8]} or its ancestors)")
    tol = float(policy.get("ratchet_tolerance_pp", 0.0))
    checks = [("Overall unit coverage does not drop (ratchet)", o_unit["percent"] + tol >= base_unit, True,
               f"{fmt_pct(o_unit['percent'])} vs {fmt_pct(base_unit)} on {source}")]
    if o_comb is not None:
        checks.append(("Overall unit + emulator coverage does not drop (ratchet)",
                       o_comb["percent"] + tol >= base_comb, True,
                       f"{fmt_pct(o_comb['percent'])} vs {fmt_pct(base_comb)} on {source}"))
    return dict(checks=checks, unit=base_unit, combined=base_comb, source=source)


def gate(args) -> int:
    policy = load_policy()
    mode = getattr(args, "mode", "unit")
    if mode == "unit" and args.combined:
        raise ValueError("combined coverage requires --mode release")
    labels = {label.strip() for label in (args.labels or "").split(",") if label.strip()}
    exempt = sorted(labels.intersection(EXEMPT_DIFF_LABELS))
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    unit_cov = parse_report(Path(args.unit))
    combined_cov = parse_report(Path(args.combined)) if args.combined and Path(args.combined).is_file() else None
    records = read_history(args.history, strict=(mode == "release"))
    combined_baseline = None
    combined_diff_baseline = None
    if mode == "release":
        # A version commit or a repeated candidate validation must cover the
        # entire batch since the previous authentic combined measurement.
        ancestors = git_ancestors(args.head, limit=None, strict=True)
        previous = ancestors[1:]
        base_sha = ancestors[0]
        baseline, match = select_baseline(records, base_sha, ancestors)
        combined_baseline, _ = select_baseline(records, base_sha, ancestors, "combined")
        combined_diff_baseline, _ = select_baseline(records, "", previous, "combined")
        if combined_diff_baseline:
            diff_base = combined_diff_baseline["sha"]
        else:
            # First release: all production code must meet the combined diff
            # floor. There is no invented measurement for a prior commit.
            diff_base = subprocess.check_output(
                ["git", "hash-object", "-t", "tree", "-w", "--stdin"],
                input="", cwd=REPO, text=True).strip()
        changes = changed_lines(diff_base, args.head, direct=True)
    else:
        ancestors = git_ancestors(args.base_sha or git_merge_base(args.base, args.head))
        base_sha = ancestors[0]
        baseline, match = select_baseline(records, base_sha, ancestors)
        diff_base = git_merge_base(args.base, args.head)
        changes = changed_lines(args.base, args.head)
    d_unit = diff_stats(unit_cov, changes)
    d_comb = diff_stats(combined_cov, changes) if combined_cov is not None else None
    o_unit = overall(unit_cov)
    o_comb = overall(combined_cov) if combined_cov is not None else None
    checks = []  # (name, ok, blocking, detail)

    def add(name, ok, blocking, detail):
        checks.append(dict(name=name, ok=bool(ok), blocking=bool(blocking), detail=detail))

    unit_min = float(policy["diff_unit_min"])
    comb_min = float(policy["diff_combined_min"])
    if mode == "unit":
        add(f"Diff coverage, unit specs ≥ {unit_min:.0f}%",
            d_unit["executable"] == 0 or d_unit["percent"] >= unit_min, not exempt,
            f"{d_unit['percent']:.1f}% ({d_unit['covered']}/{d_unit['executable']} changed executable lines)")
    elif d_comb is None or not o_comb["executable"]:
        add("Authentic release combined coverage is available", False, True,
            "release requires unit + real emulator coverage; no unit-only fallback")
    else:
        add(f"Diff coverage, unit + emulator ≥ {comb_min:.0f}%",
            d_comb["executable"] == 0 or d_comb["percent"] >= comb_min, True,
            f"{d_comb['percent']:.1f}% ({d_comb['covered']}/{d_comb['executable']}); diff from {diff_base[:8]}")
    ratchet = ratchet_checks(policy, o_unit, None, baseline, match, base_sha)
    for name, ok, blocking, detail in ratchet["checks"]:
        add(name, ok, blocking, detail)
    combined_floor = policy["day_one_baseline"]["combined"]
    if combined_baseline:
        combined_floor = combined_baseline["combined"]["percent"]
    if mode == "release":
        proofs = merge_release_checks(*(record.get("release_checks", {}) for record in records))
        combined_floor = max([combined_floor, *(proof["combined"] for proof in proofs.values()
                                                if proof.get("sha") in ancestors)])
    if mode == "release" and o_comb is not None:
        add("Overall unit + emulator coverage does not drop (ratchet)",
            o_comb["percent"] + float(policy.get("ratchet_tolerance_pp", 0)) >= combined_floor, True,
            f"{fmt_pct(o_comb['percent'])} vs {fmt_pct(combined_floor)}; nearest real combined record "
            + (combined_baseline["sha"][:8] if combined_baseline else "none (day-one floor)"))
    for name, ok, blocking, detail in target_checks(policy, today, o_unit, o_comb, unit_cov, mode):
        add(name, ok, blocking, detail)

    failed_blocking = [c for c in checks if c["blocking"] and not c["ok"]]
    md = [f"### Coverage ({mode}): {'✅ pass' if not failed_blocking else '❌ fail'}", ""]
    md += ["| Check | Result | Blocking | Detail |", "| --- | --- | --- | --- |"]
    for c in checks:
        md.append(f"| {c['name']} | {'✅' if c['ok'] else '❌'} | {'yes' if c['blocking'] else 'no'} | {c['detail']} |")
    if exempt and mode == "unit":
        md += ["", f"Diff-coverage gates waived by label `{exempt[0]}`; ratchet and active targets still apply."]
    md += ["", f"Overall: unit {fmt_pct(o_unit['percent'])} ({o_unit['covered']}/{o_unit['executable']} lines, "
               f"{o_unit['files']} files)"
           + (f" · unit + emulator {fmt_pct(o_comb['percent'])} ({o_comb['covered']}/{o_comb['executable']})"
              if o_comb else "")]
    history = [record for record in records if record.get("combined")][-8:]
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
            mode=mode, diff_base=diff_base, measured_sha=base_sha if mode == "release" else None,
            run_id=int(os.environ.get("GITHUB_RUN_ID", "0")),
            run_attempt=int(os.environ.get("GITHUB_RUN_ATTEMPT", "0")),
            baseline_unit=ratchet["unit"], baseline_combined=combined_floor if mode == "release" else None,
            combined_baseline_sha=combined_baseline["sha"] if combined_baseline else None,
            combined_diff_baseline_sha=combined_diff_baseline["sha"] if combined_diff_baseline else None,
            baseline_sha=baseline.get("sha") if baseline else None, baseline_match=match, base_sha=base_sha,
            passed=not failed_blocking),
            ensure_ascii=False, indent=2), encoding="utf-8")
    print(text)
    return 0 if not failed_blocking else 1


def target_summary(target: dict) -> str:
    parts = []
    if "combined" in target:
        parts.append(f"unit + emulator ≥ {target['combined']['effective']:.2f}%")
    if "unit" in target:
        parts.append(f"unit ≥ {target['unit']['effective']:.2f}%")
    if "module_unit" in target:
        floor = target["module_unit"]
        parts.append(f"each `{floor['pattern']}` file unit ≥ {floor['min']:.0f}%")
    return f"from {target['date']}: " + ", ".join(parts)


def badge_color(percent: float) -> str:
    for limit, color in ((90, "brightgreen"), (85, "green"), (75, "yellowgreen"), (65, "yellow"), (50, "orange")):
        if percent >= limit:
            return color
    return "red"


def is_newest_publish(baseline_path: Path, sha: str, cwd=REPO) -> bool:
    """True unless baseline.json already holds a commit that sha is an ancestor of.

    Coverage runs for main commits may finish out of order; history.jsonl keeps
    every commit (keyed by SHA, what the PR ratchet reads) while baseline.json
    and the badges only move forward.
    """
    if not baseline_path.is_file():
        return True
    try:
        current = json.loads(baseline_path.read_text(encoding="utf-8")).get("sha", "")
    except json.JSONDecodeError:
        return True
    if not current or current == sha:
        return True
    older = subprocess.run(["git", "merge-base", "--is-ancestor", sha, current], cwd=cwd,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    return not older


def baseline(args) -> int:
    policy = load_policy()
    tolerance = float(policy.get("ratchet_tolerance_pp", 0))
    unit = overall(parse_report(Path(args.unit)))
    combined = overall(parse_report(Path(args.combined))) if args.combined else None
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    record = dict(sha=args.sha, date=now, unit=unit, run=args.run_url or "")
    if combined is not None:
        record["combined"] = combined
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    history_path = out / "history.jsonl"
    previous = read_history(history_path, strict=history_path.exists())
    if any(not isinstance(entry.get("date"), str) or not entry["date"] for entry in previous):
        raise ValueError("coverage history contains an invalid publication date")
    checks_path = getattr(args, "release_checks", None)
    checks = validate_release_checks(json.loads(Path(checks_path).read_text())) if checks_path else {}
    publication_attempt = getattr(args, "publication_attempt", None)
    if publication_attempt is not None:
        run_id = (args.run_url or "").rstrip("/").split("/")[-1]
        own = checks.get(run_id, {})
        if (publication_attempt <= 0 or own.get("sha") != args.sha or combined is None
                or own.get("combined", -1) < combined["percent"]
                or combined["percent"] + tolerance < own.get("combined", 101)):
            raise ValueError("persistence retry does not match the accepted release")
        checks[run_id] = dict(own, attempt=max(own["attempt"], publication_attempt))
    all_checks = merge_release_checks(*(entry.get("release_checks", {}) for entry in previous), checks)
    for check in all_checks.values():
        if combined is not None and check.get("sha") == args.sha and combined["percent"] + tolerance < check["combined"]:
            raise ValueError("publication would erase a durable accepted release floor")
    existing = next((entry for entry in reversed(previous) if entry["sha"] == args.sha), None)
    if combined is None and existing and existing.get("combined"):
        record = existing  # A late unit publisher cannot erase a true combined measurement.
    merged_checks = merge_release_checks(existing.get("release_checks", {}) if existing else {}, checks)
    if merged_checks:
        record["release_checks"] = merged_checks
    entries = [entry for entry in previous if entry["sha"] != args.sha] + [record]
    (out / "history.jsonl").write_text("".join(json.dumps(entry) + "\n" for entry in entries), encoding="utf-8")
    if is_newest_publish(out / "baseline.json", args.sha):
        (out / "baseline.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        (out / "badge-unit.json").write_text(json.dumps(dict(
            schemaVersion=1, label="unit coverage", message=f"{record['unit']['percent']:.1f}%",
            color=badge_color(record["unit"]["percent"]))) + "\n", encoding="utf-8")
    else:
        print(f"{args.sha[:8]} is older than the published baseline.json; history only")
    # Keep the combined badge on the nearest authentic measurement, even
    # when a release finishes after a newer main unit-only record.
    try:
        visible = json.loads((out / "baseline.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        visible = None
    if visible:
        measured, _ = select_baseline(entries, visible["sha"], git_ancestors(visible["sha"], limit=None), "combined")
        if measured:
            value = measured["combined"]["percent"]
            (out / "badge.json").write_text(json.dumps(dict(
                schemaVersion=1, label="release coverage", message=f"{value:.1f}%",
                color=badge_color(value))) + "\n", encoding="utf-8")
    policy = load_policy()
    lines = ["# Coverage history (main)", "",
             "Unit coverage follows main CI; combined coverage is measured only by Release candidates. "
             "A dash means no emulator measurement for that commit. "
             "Scope: `main.lua`, `weread/`, `integrations/`. Policy: `.ci/coverage-policy.json` on main.", "",
             "Targets: " + "; ".join(target_summary(t) for t in effective_targets(policy)), "",
             "| Date (UTC) | Commit | Unit | Unit + emulator | Run |", "| --- | --- | --- | --- | --- |"]
    for entry in reversed(entries[-100:]):
        run = f"[run]({entry['run']})" if entry.get("run") else ""
        measured = f"{entry['combined']['percent']:.2f}%" if entry.get("combined") else "—"
        lines.append(f"| {entry['date']} | `{entry['sha'][:8]}` | {entry['unit']['percent']:.2f}% "
                     f"| {measured} | {run} |")
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
    p.add_argument("--mode", choices=("unit", "release"), default="unit")
    p.add_argument("--unit", required=True)
    p.add_argument("--combined")
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--labels", default="")
    p.add_argument("--history", help="history.jsonl of the coverage branch (per-commit main coverage)")
    p.add_argument("--base-sha",
                   help="main commit the PR is measured against (default: merge-base of --base and --head)")
    p.add_argument("--today")
    p.add_argument("--summary")
    p.add_argument("--json")
    p = sub.add_parser("baseline")
    p.add_argument("--unit", required=True)
    p.add_argument("--combined", help="authentic release report; omit for unit-only main records")
    p.add_argument("--sha", required=True)
    p.add_argument("--run-url")
    p.add_argument("--publication-attempt", type=int, help="acknowledge the persistence retry without rerunning tests")
    p.add_argument("--release-checks", help="durable checked run/attempt watermarks from the accepted gate")
    p.add_argument("--out-dir", required=True)
    args = parser.parse_args()
    return dict(merge=merge, report=report, diff=diff, total=total, gate=gate, baseline=baseline)[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
