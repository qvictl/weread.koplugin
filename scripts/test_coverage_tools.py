#!/usr/bin/env python3
"""Offline tests for scripts/coverage_tools.py (report parsing, dated targets, ratchet baseline).

    python3 scripts/test_coverage_tools.py
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import coverage_tools as ct  # noqa: E402

BAR = "=" * 78


def luacov_report(files: dict) -> str:
    """Renders {name: [(hits or None, source), ...]} like LuaCov's DefaultReporter."""
    most = max([hits for rows in files.values() for hits, _src in rows if hits is not None] or [0])
    digits = len(str(most))
    out = []
    for name, rows in files.items():
        out += [BAR, name, BAR]
        for hits, source in rows:
            if hits is None:
                out.append(source if source == "" else " " * (digits + 1) + " " + source)
            elif hits == 0:
                out.append("*" * digits + "0 " + source)
            else:
                out.append(f"{hits:>{digits + 1}d} " + source)
        out.append("")
    out += [BAR, "Summary", BAR, "", "File  Hits Missed Coverage"]
    return "\n".join(out) + "\n"


def parse(text: str) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "report.out"
        path.write_text(text, encoding="utf-8")
        return ct.parse_report(path)


class ParseReportTest(unittest.TestCase):
    ROWS = [
        (None, "-- header comment"),
        (1, "local M = {}"),
        (None, ""),
        (0, "local function unused() end"),
        (None, "--[[ 12345 starts with digits ]]"),
        (3, "return M"),
    ]

    def check_width(self, top_hits: int) -> None:
        rows = list(self.ROWS) + [(top_hits, "M.hot = true")]
        cov = parse(luacov_report({"weread/lib/m.lua": rows, "spec/ignored_spec.lua": [(5, "x()")]}))
        self.assertEqual(set(cov), {"weread/lib/m.lua"}, "spec files are never counted")
        self.assertEqual(cov["weread/lib/m.lua"], {2: 1, 4: 0, 6: 3, 7: top_hits})

    def test_column_width_follows_the_highest_hit_count(self):
        # CI reports had 8-digit maxima (9-character column); smaller and larger
        # maxima must parse the same way instead of misreading the column.
        for top in (7, 4096, 15540528, 123456789, 98765432101):
            with self.subTest(top=top):
                self.check_width(top)

    def test_hit_column_width(self):
        self.assertEqual(ct.hit_column_width(["***0 x", "   12 y", "        z"]), 4)
        self.assertEqual(ct.hit_column_width(["     5 a", "  9999 b"]), 6)
        self.assertEqual(ct.hit_column_width(["no hits here"]), 9)

    def test_overall(self):
        cov = parse(luacov_report({"main.lua": [(1, "a"), (0, "b")], "weread/x.lua": [(2, "c"), (2, "d")]}))
        self.assertEqual(ct.overall(cov), dict(percent=75.0, covered=3, executable=4, files=2))


POLICY = {
    "day_one_baseline": {"date": "2026-10-27", "unit": 73.8, "combined": 80.78},
    "targets": [
        {"label": "4 weeks", "date": "2026-11-24", "combined_min": 75, "unit_min": 80},
        {"label": "8 weeks", "date": "2026-12-22", "combined_min": 85, "unit_min": 88,
         "module_unit_min": {"pattern": "^weread/lib/", "min": 70}},
        {"label": "legacy", "date": "2027-01-01", "unit_min": 50},
    ],
}


def cov_at(percent: int) -> dict:
    """Ten executable lines, `percent` of them hit."""
    hits = percent // 10
    return {line: (1 if line <= hits else 0) for line in range(1, 11)}


class TargetsTest(unittest.TestCase):
    def test_effective_targets_take_the_day_one_baseline_per_kind(self):
        targets = ct.effective_targets(POLICY)
        self.assertEqual(targets[0]["combined"], dict(configured=75.0, effective=80.78))
        self.assertEqual(targets[0]["unit"], dict(configured=80.0, effective=80.0))
        self.assertEqual(targets[1]["module_unit"], dict(pattern="^weread/lib/", min=70.0))
        self.assertNotIn("module_unit", targets[0])
        # unit-only target: configured below the day-one unit baseline -> baseline wins
        self.assertEqual(targets[2]["unit"], dict(configured=50.0, effective=73.8))
        self.assertNotIn("combined", targets[2])

    def test_old_policy_shape_still_works(self):
        policy = {"day_one_baseline": {"combined": 80.0},
                  "targets": [{"date": "2026-11-24", "combined_min": 75}]}
        (target,) = ct.effective_targets(policy)
        self.assertEqual(target["combined"]["effective"], 80.0)
        self.assertNotIn("unit", target)

    def test_module_floor_misses(self):
        unit_cov = {"weread/lib/a.lua": cov_at(60), "weread/lib/b.lua": cov_at(70),
                    "weread/lib/c.lua": cov_at(0), "weread/ui/d.lua": cov_at(10), "weread/lib/empty.lua": {}}
        self.assertEqual(ct.module_floor_misses(unit_cov, "^weread/lib/", 70),
                         [("weread/lib/c.lua", 0.0), ("weread/lib/a.lua", 60.0)])

    def run_checks(self, today: str, unit: float, combined, unit_cov: dict) -> dict:
        o_comb = None if combined is None else dict(percent=combined)
        checks = ct.target_checks(POLICY, dt.date.fromisoformat(today), dict(percent=unit), o_comb, unit_cov)
        return {name: (ok, blocking) for name, ok, blocking, _detail in checks}

    def test_report_only_before_the_date_blocking_from_it(self):
        lib = {"weread/lib/a.lua": cov_at(60)}
        before = self.run_checks("2026-11-23", 79.9, 81.0, lib)
        self.assertEqual(before["Target 4 weeks: overall unit ≥ 80.00% (report-only until 2026-11-24)"],
                         (False, False))
        self.assertEqual(before["Target 4 weeks: overall unit + emulator ≥ 80.78% (report-only until 2026-11-24)"],
                         (True, False))
        on = self.run_checks("2026-11-24", 79.9, 81.0, lib)
        self.assertEqual(on["Target 4 weeks: overall unit ≥ 80.00%"], (False, True))
        self.assertEqual(on["Target 4 weeks: overall unit + emulator ≥ 80.78%"], (True, True))
        self.assertEqual(on["Target 8 weeks: each file matching `^weread/lib/` unit ≥ 70% "
                            "(report-only until 2026-12-22)"], (False, False))
        late = self.run_checks("2026-12-22", 88.0, 85.0, {"weread/lib/a.lua": cov_at(70)})
        self.assertTrue(all(blocking for name, (_ok, blocking) in late.items() if "legacy" not in name))
        self.assertEqual(late["Target legacy: overall unit ≥ 73.80% (report-only until 2027-01-01)"], (True, False))
        self.assertEqual(late["Target 8 weeks: overall unit ≥ 88.00%"], (True, True))
        self.assertEqual(late["Target 8 weeks: each file matching `^weread/lib/` unit ≥ 70%"], (True, True))

    def test_missing_emulator_coverage_fails_combined_targets_only(self):
        checks = self.run_checks("2026-12-22", 90.0, None, {})
        self.assertEqual(checks["Target 8 weeks: overall unit + emulator ≥ 85.00%"], (False, True))
        self.assertEqual(checks["Target 8 weeks: overall unit ≥ 88.00%"], (True, True))

    def test_target_summary(self):
        targets = ct.effective_targets(POLICY)
        self.assertEqual(ct.target_summary(targets[0]), "from 2026-11-24: unit + emulator ≥ 80.78%, unit ≥ 80.00%")
        self.assertEqual(ct.target_summary(targets[1]),
                         "from 2026-12-22: unit + emulator ≥ 85.00%, unit ≥ 88.00%, each `^weread/lib/` file unit ≥ 70%")

    def test_repository_policy_is_well_formed(self):
        targets = ct.effective_targets(ct.load_policy())
        self.assertTrue(targets, "the repository policy defines dated targets")
        for target in targets:
            dt.date.fromisoformat(target["date"])
            self.assertTrue({"combined", "unit"} & set(target), target)


def record(sha: str, unit: float, combined: float) -> dict:
    return dict(sha=sha, date="2026-10-28T00:00:00+00:00", unit=dict(percent=unit), combined=dict(percent=combined))


class GitRepo:
    """Throw-away linear repository; commits() returns SHAs oldest first."""

    def __init__(self, tmp: str, count: int):
        self.path = tmp
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        self.git("init", "-q", env=env)
        self.shas = []
        for index in range(count):
            self.git("commit", "-q", "--allow-empty", "-m", f"c{index}", env=env)
            self.shas.append(self.git("rev-parse", "HEAD"))

    def git(self, *argv, env=None) -> str:
        return subprocess.check_output(["git", *argv], cwd=self.path, text=True, env=env).strip()


class RatchetBaselineTest(unittest.TestCase):
    def test_exact_base_commit(self):
        records = [record("a", 70, 80), record("b", 71, 81)]
        chosen, match = ct.select_baseline(records, "a", ["a"])
        self.assertEqual((chosen["sha"], match), ("a", "exact"))

    def test_missing_sha_falls_back_to_nearest_ancestor(self):
        records = [record("a", 70, 80), record("b", 71, 81), record("d", 75, 85)]
        # base c has no record (its coverage run failed or was superseded); b is its parent
        chosen, match = ct.select_baseline(records, "c", ["c", "b", "a"])
        self.assertEqual((chosen["sha"], match), ("b", "ancestor"))

    def test_no_recorded_ancestor_uses_day_one(self):
        chosen, match = ct.select_baseline([record("x", 90, 95)], "c", ["c", "b"])
        self.assertEqual((chosen, match), (None, "none"))
        result = ct.ratchet_checks(POLICY, dict(percent=73.8), dict(percent=80.78), chosen, match, "c")
        self.assertEqual((result["unit"], result["combined"]), (73.8, 80.78))
        self.assertTrue(all(ok for _name, ok, _blocking, _detail in result["checks"]))
        self.assertIn("day-one baseline", result["source"])

    def test_republished_sha_last_record_wins(self):
        chosen, _match = ct.select_baseline([record("a", 70, 80), record("a", 72, 82)], "a", ["a"])
        self.assertEqual(chosen["unit"]["percent"], 72)

    def test_git_ancestors_walk_real_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = GitRepo(tmp, 4)
            c0, c1, c2, c3 = repo.shas
            self.assertEqual(ct.git_ancestors(c3, cwd=tmp), [c3, c2, c1, c0])
            self.assertEqual(ct.git_ancestors("0" * 40, cwd=tmp), ["0" * 40])
            chosen, match = ct.select_baseline([record(c0, 70, 80), record(c1, 71, 81)], c3,
                                               ct.git_ancestors(c3, cwd=tmp))
            self.assertEqual((chosen["sha"], match), (c1, "ancestor"))

    def ratchet_ok(self, records, base, ancestors, unit, combined):
        chosen, match = ct.select_baseline(records, base, ancestors)
        result = ct.ratchet_checks(POLICY, dict(percent=unit), dict(percent=combined), chosen, match, base)
        return all(ok for _name, ok, _blocking, _detail in result["checks"]), result

    def test_parallel_prs_each_judged_against_their_own_base(self):
        # main: A, then B = A + another PR that added tests (coverage went up)
        history = [record("A", 74.00, 80.00), record("B", 74.50, 81.00)]
        # PR 1 branched from A, keeps A's coverage: passes although B is higher now
        ok1, result1 = self.ratchet_ok(history, "A", ["A"], 74.00, 80.00)
        self.assertTrue(ok1, result1)
        self.assertIn("main@A", result1["source"])
        # what the old "latest main" ratchet did to PR 1
        stale, _ = self.ratchet_ok(history, "B", ["B", "A"], 74.00, 80.00)
        self.assertFalse(stale)
        # PR 2 branched from B keeps B's coverage: passes too
        ok2, _ = self.ratchet_ok(history, "B", ["B", "A"], 74.50, 81.00)
        self.assertTrue(ok2)
        # both in flight together, whatever merges first: still independent
        history.append(record("C", 74.50, 81.00))
        self.assertTrue(self.ratchet_ok(history, "A", ["A"], 74.00, 80.00)[0])
        self.assertTrue(self.ratchet_ok(history, "B", ["B", "A"], 74.50, 81.00)[0])

    def test_drop_against_own_base_fails_beyond_tolerance(self):
        history = [record("A", 74.00, 80.00), record("B", 74.50, 81.00)]
        policy = dict(POLICY, ratchet_tolerance_pp=0.1)
        chosen, match = ct.select_baseline(history, "B", ["B", "A"])
        within = ct.ratchet_checks(policy, dict(percent=74.41), dict(percent=80.91), chosen, match, "B")
        self.assertTrue(all(ok for _n, ok, _b, _d in within["checks"]))
        unit_drop = ct.ratchet_checks(policy, dict(percent=74.30), dict(percent=81.00), chosen, match, "B")
        self.assertEqual([ok for _n, ok, _b, _d in unit_drop["checks"]], [False, True])
        comb_drop = ct.ratchet_checks(policy, dict(percent=74.50), dict(percent=80.80), chosen, match, "B")
        self.assertEqual([ok for _n, ok, _b, _d in comb_drop["checks"]], [True, False])
        self.assertTrue(all(blocking for _n, _ok, blocking, _d in comb_drop["checks"]))

    def test_read_history_skips_bad_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "history.jsonl"
            path.write_text(json.dumps(record("a", 1, 2)) + "\nnot json\n{}\n" + json.dumps(record("b", 3, 4)) + "\n",
                            encoding="utf-8")
            self.assertEqual([r["sha"] for r in ct.read_history(path)], ["a", "b"])
            self.assertEqual(ct.read_history(Path(tmp) / "missing.jsonl"), [])
            self.assertEqual(ct.read_history(None), [])

    def test_out_of_order_publish_keeps_baseline_json_on_the_newest_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = GitRepo(tmp, 3)
            c0, _c1, c2 = repo.shas
            path = Path(tmp) / "baseline.json"
            self.assertTrue(ct.is_newest_publish(path, c0, cwd=tmp))
            path.write_text(json.dumps(record(c2, 1, 2)), encoding="utf-8")
            self.assertFalse(ct.is_newest_publish(path, c0, cwd=tmp))
            self.assertTrue(ct.is_newest_publish(path, c2, cwd=tmp))
            path.write_text(json.dumps(record(c0, 1, 2)), encoding="utf-8")
            self.assertTrue(ct.is_newest_publish(path, c2, cwd=tmp))

    def test_baseline_command_keys_history_by_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.out"
            report.write_text(luacov_report({"weread/lib/m.lua": [(1, "a()"), (0, "b()")]}), encoding="utf-8")
            site = Path(tmp) / "site"

            def publish(sha):
                args = argparse.Namespace(unit=str(report), combined=str(report), sha=sha, run_url="",
                                          out_dir=str(site))
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(ct.baseline(args), 0)

            publish("a" * 40)
            publish("b" * 40)
            publish("a" * 40)  # re-run of the same commit replaces its record
            shas = [r["sha"] for r in ct.read_history(site / "history.jsonl")]
            self.assertEqual(shas, ["b" * 40, "a" * 40])
            self.assertEqual(json.loads((site / "baseline.json").read_text())["unit"]["percent"], 50.0)

    def test_baseline_command_older_commit_updates_history_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.out"
            report.write_text(luacov_report({"weread/lib/m.lua": [(1, "a()"), (0, "b()")]}), encoding="utf-8")
            site = Path(tmp) / "site"
            site.mkdir()
            published = {name: f"{name} of the newer commit\n"
                         for name in ("baseline.json", "badge.json", "badge-unit.json")}
            for name, text in published.items():
                (site / name).write_text(text, encoding="utf-8")
            args = argparse.Namespace(unit=str(report), combined=str(report), sha="c" * 40, run_url="",
                                      out_dir=str(site))
            with mock.patch.object(ct, "is_newest_publish", return_value=False), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ct.baseline(args), 0)
            self.assertEqual([r["sha"] for r in ct.read_history(site / "history.jsonl")], ["c" * 40])
            for name, text in published.items():
                self.assertEqual((site / name).read_text(encoding="utf-8"), text, name)


class CoveragePhaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = GitRepo(self.tmp.name, 0)
        self.env = dict(os.environ, COVERAGE_REPO=self.tmp.name, GIT_AUTHOR_NAME="t",
                        GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@example.com")
        (self.root / ".ci").mkdir()
        policy = dict(POLICY, diff_unit_min=80, diff_combined_min=90, ratchet_tolerance_pp=0.1)
        (self.root / ".ci/coverage-policy.json").write_text(json.dumps(policy))
        (self.root / "weread/lib").mkdir(parents=True)
        self.module = self.root / "weread/lib/m.lua"
        self.rows = ["old_%d()" % i for i in range(10)]
        self.module.write_text("\n".join(self.rows) + "\n")
        (self.root / "_meta.lua").write_text('version = "1.0.0"\n')
        self.base = self.commit("previous release")
        self.rows[:5] = ["new_%d()" % i for i in range(5)]
        self.module.write_text("\n".join(self.rows) + "\n")
        self.production = self.commit("unreleased production change")
        (self.root / "_meta.lua").write_text('version = "1.0.1"\n')
        self.candidate = self.commit("version-only candidate")
        self.unit = self.report("unit", [])

    def commit(self, title):
        self.repo.git("add", ".")
        self.repo.git("commit", "-qm", title, env=self.env)
        return self.repo.git("rev-parse", "HEAD")

    def report(self, name, missed):
        path = self.root / (name + ".report")
        path.write_text(luacov_report({"weread/lib/m.lua": [
            (0 if i in missed else 1, row) for i, row in enumerate(self.rows)]}))
        return path

    def history_record(self, sha, combined=None):
        result = dict(sha=sha, date="2026-10-28", unit=dict(percent=80), run="")
        if combined is not None:
            result["combined"] = dict(percent=combined)
        return result

    def run_gate(self, mode, combined=None, records=None, **options):
        history = self.root / "history.jsonl"
        if records is None:
            records = [self.history_record(self.base, 90), self.history_record(self.production)]
        history.write_text("".join(json.dumps(r) + "\n" for r in records))
        output = self.root / "gate.json"
        args = [sys.executable, ct.__file__, "gate", "--mode", mode, "--unit", str(self.unit),
                "--base", self.production, "--head", self.candidate, "--history", str(history),
                "--today", options.get("today", "2026-10-28"), "--json", str(output)]
        if combined is not None:
            args += ["--combined", str(combined)]
        if options.get("labels"):
            args += ["--labels", options["labels"]]
        process = subprocess.run(args, cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertTrue(output.is_file(), process.stderr)
        return process.returncode, json.loads(output.read_text())

    def test_unit_mode_never_requires_emulator_even_after_combined_target_dates(self):
        code, data = self.run_gate("unit", today="2027-01-02")
        self.assertEqual(code, 0, data)
        self.assertIsNone(data["overall_combined"])
        self.assertFalse(any("emulator" in item["name"] for item in data["checks"]))

    def test_release_diff_spans_production_and_skips_unit_only_history(self):
        code, data = self.run_gate("release", self.report("combined", [0]), labels="no-tests-needed")
        self.assertEqual(code, 1)
        self.assertEqual(data["diff_base"], self.base)
        self.assertEqual(data["diff_combined"]["executable"], 5)
        self.assertEqual(data["diff_combined"]["percent"], 80)
        self.assertEqual(data["combined_diff_baseline_sha"], self.base)

    def test_same_candidate_record_is_excluded_from_diff_but_keeps_high_ratchet(self):
        history = [self.history_record(self.base, 90), self.history_record(self.production),
                   self.history_record(self.candidate, 100)]
        code, data = self.run_gate("release", self.report("combined", [9]), history)
        self.assertEqual(data["diff_combined"]["percent"], 100)
        self.assertEqual(data["diff_base"], self.base)
        self.assertEqual(data["combined_baseline_sha"], self.candidate)
        self.assertEqual(data["baseline_combined"], 100)
        self.assertEqual(code, 1, "same-source coverage fell but an older low floor hid it")

    def test_release_git_history_failure_cannot_lower_the_ratchet(self):
        import shutil
        binary = self.root / "bin"
        binary.mkdir()
        wrapper = binary / "git"
        wrapper.write_text('#!/bin/sh\nif [ "$1" = rev-list ]; then exit 9; fi\nexec "' + shutil.which("git") + '" "$@"\n')
        wrapper.chmod(0o755)
        history = self.root / "history.jsonl"
        history.write_text(json.dumps(self.history_record(self.base, 95)) + "\n")
        output = self.root / "gate.json"
        env = dict(self.env, PATH=str(binary) + os.pathsep + self.env["PATH"])
        process = subprocess.run([sys.executable, ct.__file__, "gate", "--mode", "release",
                                  "--unit", str(self.unit), "--combined", str(self.report("combined", [9])),
                                  "--base", self.base, "--head", self.candidate, "--history", str(history),
                                  "--today", "2026-10-28", "--json", str(output)],
                                 cwd=self.root, env=env, capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0, "Git failure was reclassified as a first release")
        self.assertFalse(output.exists(), "unreadable history produced a passing measurement")

    def test_first_release_counts_all_code_and_never_fakes_combined(self):
        code, data = self.run_gate("release", self.report("combined", [9]), records=[])
        self.assertEqual(code, 0, data)
        self.assertEqual(data["diff_combined"]["executable"], 10)
        self.assertIsNone(data["combined_diff_baseline_sha"])
        code, data = self.run_gate("release", labels="upstream-sync")
        self.assertEqual(code, 1)
        self.assertIsNone(data["overall_combined"])

    def test_unit_diff_floor_and_ratchet_remain_blocking(self):
        self.candidate = self.production
        self.production = self.base
        self.unit = self.report("unit", [0])
        self.assertEqual(self.run_gate("unit")[0], 0)
        self.unit = self.report("unit", [0, 1])
        self.assertEqual(self.run_gate("unit")[0], 1)

    def test_unit_publisher_preserves_real_combined_and_separate_latest_badge(self):
        site = self.root / "site"
        def publish(sha, combined=None):
            args = [sys.executable, ct.__file__, "baseline", "--unit", str(self.unit),
                    "--sha", sha, "--out-dir", str(site)]
            if combined:
                args += ["--combined", str(combined)]
            subprocess.run(args, cwd=self.root, env=self.env, capture_output=True, check=True)
        publish(self.production)
        publish(self.base, self.report("combined", [9]))
        self.assertEqual(json.loads((site / "baseline.json").read_text())["sha"], self.production)
        self.assertEqual(json.loads((site / "badge.json").read_text())["message"], "90.0%")
        publish(self.base)
        publish(self.candidate)
        records = {r["sha"]: r for r in ct.read_history(site / "history.jsonl")}
        self.assertEqual(records[self.base]["combined"]["percent"], 90)
        self.assertNotIn("combined", records[self.candidate])
        self.assertEqual(json.loads((site / "badge.json").read_text())["message"], "90.0%")
        self.assertIn("—", (site / "README.md").read_text())


if __name__ == "__main__":
    unittest.main()
