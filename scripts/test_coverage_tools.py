#!/usr/bin/env python3
"""Offline tests for scripts/coverage_tools.py (report parsing and dated targets).

    python3 scripts/test_coverage_tools.py
"""

from __future__ import annotations

import datetime as dt
from pathlib import Path
import sys
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
