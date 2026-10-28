#!/usr/bin/env python3
"""Benchmark a synthetic 200/811-chapter download with real cancel and resume.

Run on both revisions with the same KOReader runtime and chapter count.
Evidence includes UI timings, parent RSS/Lua peaks, sampled process-tree RSS/PSS,
the mock request log and EPUB chapter verification. No real account is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading

import mock_weread
import run_emulator_scenarios as runner


def tree_memory(pid):
    """RSS sums shared pages repeatedly; PSS apportions them across processes."""
    pending, seen = [pid], set()
    rss = pss = 0
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        try:
            root = Path(f"/proc/{current}")
            values = {}
            for line in (root / "smaps_rollup").read_text().splitlines():
                key, _, value = line.partition(":")
                if key in ("Rss", "Pss"):
                    values[key] = int(value.split()[0])
            rss += values.get("Rss", 0)
            pss += values.get("Pss", 0)
            seen.add(current)
            pending += [int(child) for child in (root / f"task/{current}/children").read_text().split()]
        except (OSError, ValueError):
            continue
    return rss, pss, len(seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--chapters", type=int, choices=(200, 811), default=811)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    mock_weread.BIG_CHAPTER_COUNT = args.chapters
    mock_weread.BIG_CHAPTERS = [dict(chapterUid=i, chapterIdx=i, title=f"第{i}章 长路", level=1, wordCount=1800)
                              for i in range(1, args.chapters + 1)]
    mock_weread.BIG_BOOK.update(totalChapter=args.chapters, wordCount=args.chapters * 1800)
    os.environ["WEREAD_BENCH_CHAPTERS"] = str(args.chapters)
    runtime = runner.find_runtime(args.koreader, out)
    candidate = runner.build_candidate(out)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=runner.REPO, text=True).strip()
    candidate_sha256 = hashlib.sha256(candidate.read_bytes()).hexdigest()
    sample = {"tree_peak_rss_kb": 0, "tree_peak_pss_kb": 0, "processes_peak": 0, "samples": 0}
    stop = threading.Event()
    threads = []
    popen = subprocess.Popen

    def sampled_popen(command, *positional, **kwargs):
        process = popen(command, *positional, **kwargs)
        if isinstance(command, list) and "./reader.lua" in command:
            def monitor():
                while not stop.is_set():
                    rss, pss, processes = tree_memory(process.pid)
                    sample["tree_peak_rss_kb"] = max(sample["tree_peak_rss_kb"], rss)
                    sample["tree_peak_pss_kb"] = max(sample["tree_peak_pss_kb"], pss)
                    sample["processes_peak"] = max(sample["processes_peak"], processes)
                    sample["samples"] += 1
                    stop.wait(0.1)
            thread = threading.Thread(target=monitor, daemon=True)
            thread.start()
            threads.append(thread)
        return process

    subprocess.Popen = sampled_popen
    try:
        options = argparse.Namespace(width=600, height=800, dpi=167, coverage=False, xvfb=False)
        scenario = runner.REPO / "spec/emulator/benchmarks/download_scheduler.lua"
        result = runner.run_scenario(scenario, runtime, candidate, out, options)
    finally:
        stop.set()
        for thread in threads:
            thread.join()
        subprocess.Popen = popen
    result["process_tree_memory"] = sample
    result["revision"] = revision
    result["candidate_sha256"] = candidate_sha256
    (out / "benchmark.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
