#!/usr/bin/env python3
"""Compare metadata-scale cache import UI latency on the same synthetic tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time

import mock_weread
import run_emulator_scenarios as runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--books", type=int, default=200)
    parser.add_argument("--chapters", type=int, default=811)
    args = parser.parse_args()
    if not 1 <= args.books <= 200 or not 1 <= args.chapters <= 811:
        parser.error("fixture is limited to 200 books and 811 files per book")
    out, fixture = args.out.resolve(), args.fixture.resolve()
    out.mkdir(parents=True, exist_ok=True)
    fixture.mkdir(parents=True, exist_ok=True)
    books = []
    for index in range(args.books):
        book_id = str(950000 + index)
        directory = fixture / book_id
        directory.mkdir(exist_ok=True)
        for chapter in range(1, args.chapters + 1):
            (directory / f"chapter-{chapter:04d}.epub").touch(exist_ok=True)
        books.append(dict(bookId=book_id, title=f"Synthetic scan {index}", author="Synthetic author"))
    mock_weread.BOOKS = books
    os.environ.update(WEREAD_SCAN_ROOT=str(fixture), WEREAD_SCAN_BOOKS=str(args.books),
                      WEREAD_SCAN_CHAPTERS=str(args.chapters))
    runtime = runner.find_runtime(args.koreader, out)
    candidate = runner.build_candidate(out)
    scenario = runner.REPO / "spec/emulator/benchmarks/cache_scan.lua"
    evidence = out / scenario.stem / "evidence"
    stop, monitor_threads = threading.Event(), []
    sample = {"parent_peak_rss_kb": 0, "samples": 0}
    popen = subprocess.Popen

    def measured_popen(command, *positional, **kwargs):
        process = popen(command, *positional, **kwargs)
        if isinstance(command, list) and "./reader.lua" in command:
            def monitor():
                while not stop.wait(0.02):
                    if (evidence / "scan-complete").exists():
                        return
                    if not (evidence / "scan-start").exists():
                        continue
                    try:
                        for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
                            if line.startswith("VmRSS:"):
                                sample["parent_peak_rss_kb"] = max(sample["parent_peak_rss_kb"], int(line.split()[1]))
                                sample["samples"] += 1
                    except OSError:
                        return
            thread = threading.Thread(target=monitor, daemon=True)
            thread.start()
            monitor_threads.append(thread)
        return process

    subprocess.Popen = measured_popen
    try:
        options = argparse.Namespace(width=600, height=800, dpi=167, coverage=False, xvfb=False)
        result = runner.run_scenario(scenario, runtime, candidate, out, options)
    finally:
        stop.set()
        for thread in monitor_threads:
            thread.join()
        subprocess.Popen = popen
    result.update(revision=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  candidate_sha256=hashlib.sha256(candidate.read_bytes()).hexdigest(),
                  source_sha256={name: hashlib.sha256((runner.REPO / name).read_bytes()).hexdigest()
                                 for name in ("weread/lib/scan.lua", "weread/ui/cache.lua", "weread/lib/book_store.lua")},
                  fixture=dict(books=args.books, chapters=args.chapters, files=args.books * args.chapters,
                               file_bytes=0, root=str(fixture)), external_memory=sample)
    (out / "benchmark.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ("ok", "metrics", "external_memory", "error")},
                     ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
