#!/usr/bin/env python3
"""Run spec/emulator scenarios inside a real, headless KOReader emulator.

Every scenario gets a fresh isolated KO_HOME with the candidate release
package (built by scripts/package_release.sh) plus the test-only
wereadtest.koplugin driver, and its own synthetic WeRead service
(scripts/mock_weread.py). No real account, credential or upstream network is
used. KOReader runs with SDL's dummy video driver (or under xvfb-run).

    python3 scripts/run_emulator_scenarios.py --koreader /path/to/koreader \
        --out /tmp/weread-emulator [--scenario 03_library] [--list]

--koreader accepts a runtime directory containing reader.lua + luajit (any
depth below it is searched) or a .tar.xz/.tar.gz/.AppImage-free tarball.
Exit status is non-zero when any scenario fails; evidence (crash.log,
requests.jsonl, screenshots, result.json) is kept per scenario and summarized
in summary.md / summary.json.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from mock_weread import MockServer  # noqa: E402

SCENARIO_DIR = REPO / "spec/emulator/scenarios"
DRIVER_DIR = REPO / "spec/emulator/wereadtest.koplugin"
UPDATE_VERSION = "9999.9.1"


def find_runtime(path: Path, scratch: Path) -> Path:
    path = path.resolve()
    if path.is_file():
        target = scratch / "koreader-runtime"
        if not target.exists():
            target.mkdir(parents=True)
            with tarfile.open(path) as archive:
                archive.extractall(target)
        path = target
    if (path / "reader.lua").is_file() and (path / "luajit").exists():
        return path
    for candidate in sorted(path.rglob("reader.lua")):
        if (candidate.parent / "luajit").exists() and (candidate.parent / "frontend").is_dir():
            return candidate.parent
    raise SystemExit(f"error: no KOReader runtime (reader.lua + luajit) below {path}")


def parse_meta(path: Path) -> dict:
    meta = dict(timeout=240, fixtures=[], title=path.stem, budget=None)
    for line in path.read_text(encoding="utf-8").splitlines()[:40]:
        match = re.match(r"^--\s*@(\w+)\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if key == "timeout":
            meta["timeout"] = int(value)
        elif key == "fixture":
            meta["fixtures"].append(value)
        elif key == "title":
            meta["title"] = value
    return meta


def build_candidate(out: Path) -> Path:
    archive = out / "candidate.zip"
    subprocess.run(["bash", str(REPO / "scripts/package_release.sh"), str(archive)], check=True,
                   stdout=subprocess.DEVNULL)
    return archive


def github_release_fixture(candidate: Path, work: Path) -> dict:
    """A newer synthetic release built from the candidate (version bumped)."""
    name = f"weread.koplugin-v{UPDATE_VERSION}.zip"
    package = work / name
    with zipfile.ZipFile(candidate) as source, zipfile.ZipFile(package, "w", zipfile.ZIP_DEFLATED) as target:
        for entry in source.infolist():
            data = source.read(entry.filename)
            if entry.filename in ("weread.koplugin/_meta.lua", "weread.koplugin/main.lua"):
                data = re.sub(rb'version\s*=\s*"[0-9.]+"', f'version = "{UPDATE_VERSION}"'.encode(), data, count=1)
            target.writestr(entry, data)
    data = package.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    return dict(version=UPDATE_VERSION, body="更新内容（模拟数据）\n\n- 合成更新，用于模拟器测试。",
                files={name: data, name + ".sha256": f"{digest}  {name}\n".encode()})


def prepare_profile(run: Path, candidate: Path, port: int, width: int, height: int) -> dict:
    profile = run / "profile"
    for directory in ("settings", "plugins"):
        (profile / directory).mkdir(parents=True)
    (run / "books").mkdir()
    (run / "evidence").mkdir()
    with zipfile.ZipFile(candidate) as package:
        package.extractall(profile / "plugins")
    shutil.copytree(DRIVER_DIR, profile / "plugins/wereadtest.koplugin")
    books = run / "books"
    (books / "readme.html").write_text(
        '<html><head><meta charset="utf-8"/></head><body><h1>WeRead emulator test</h1></body></html>',
        encoding="utf-8")
    (profile / "settings.reader.lua").write_text(
        "return {\n"
        '    language = "zh_CN",\n'
        "    quickstart_shown_version = 999999999,\n"
        "    color_rendering = false,\n"
        f'    home_dir = "{books}",\n'
        "    auto_save_settings_interval_minutes = 0,\n"
        "}\n", encoding="utf-8")
    (profile / "settings/weread-environment.lua").write_text(
        f'return {{ enabled = true, host = "127.0.0.1", port = {port} }}\n', encoding="utf-8")
    return dict(profile=profile, books=books, evidence=run / "evidence")


def run_scenario(path: Path, runtime: Path, candidate: Path, out: Path, args) -> dict:
    meta = parse_meta(path)
    run = out / path.stem
    if run.exists():
        shutil.rmtree(run)
    run.mkdir(parents=True)
    server = MockServer(0)
    paths = prepare_profile(run, candidate, server.server_port, args.width, args.height)
    server.log_path = paths["evidence"] / "requests.jsonl"
    if "github_release" in meta["fixtures"]:
        server.github_release = github_release_fixture(candidate, run)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    result_path = paths["evidence"] / "result.json"
    env = {
        **os.environ,
        "KO_HOME": str(paths["profile"]),
        "SDL_VIDEODRIVER": "dummy",
        "SDL_VIDEO_DRIVER": "dummy",
        "SDL_AUDIODRIVER": "dummy",
        "SDL_AUDIO_DRIVER": "dummy",
        "EMULATE_READER_W": str(args.width),
        "EMULATE_READER_H": str(args.height),
        "EMULATE_READER_DPI": str(args.dpi),
        "WEREAD_TEST_SCENARIO": str(path),
        "WEREAD_TEST_HARNESS_DIR": str(REPO / "spec/emulator"),
        "WEREAD_TEST_EVIDENCE": str(paths["evidence"]),
        "WEREAD_TEST_RESULT": str(result_path),
        "WEREAD_TEST_TIMEOUT": str(meta["timeout"]),
        "WEREAD_MOCK_URL": f"http://127.0.0.1:{server.server_port}",
        "WEREAD_MOCK_FIXTURE_VERSION": UPDATE_VERSION,
        # Keep every other HTTP client off the Internet as well.
        "http_proxy": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9",
        "no_proxy": "127.0.0.1,localhost",
    }
    if args.xvfb:
        env.pop("SDL_VIDEODRIVER")
        env.pop("SDL_VIDEO_DRIVER")
    command = ["./reader.lua", str(paths["books"])]
    if args.xvfb:
        command = ["xvfb-run", "-a", "-s", f"-screen 0 {args.width}x{args.height}x24"] + command
    log_path = paths["evidence"] / "crash.log"
    started = time.monotonic()
    timed_out = False
    print(f"==> {path.stem}: {meta['title']} (timeout {meta['timeout']}s)", flush=True)
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            returncode = process.wait(timeout=meta["timeout"] + 30)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                returncode = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                returncode = process.wait()
    # Reap any download/worker children the scenario left behind.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    elapsed = time.monotonic() - started
    server.shutdown()
    server.server_close()
    thread.join()
    result = dict(scenario=path.stem, title=meta["title"], ok=False, steps=[], metrics={})
    if result_path.is_file():
        try:
            result.update(json.loads(result_path.read_text(encoding="utf-8")))
        except json.JSONDecodeError as exc:
            result["error"] = f"unreadable result.json: {exc}"
    else:
        result["error"] = "KOReader exited without a scenario result (crash?)"
    if timed_out:
        result["ok"] = False
        result["error"] = f"killed after {meta['timeout'] + 30}s (hung UI loop?)"
    elif returncode != 0 and result.get("ok"):
        result["ok"] = False
        result["error"] = f"KOReader exit status {returncode}"
    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    # A Lua error inside a UI callback that KOReader merely logged still fails.
    crashes = [line for line in log_text.splitlines() if "stack traceback" in line and "SCENARIO" not in line]
    lua_errors = [line for line in log_text.splitlines()
                  if re.search(r"\bERROR\b", line) and "WeRead" in line]
    result.update(scenario=path.stem, title=meta["title"], wall_s=round(elapsed, 1), returncode=returncode,
                  weread_error_lines=len(lua_errors), traceback_lines=len(crashes))
    (paths["evidence"] / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    status = "PASS" if result["ok"] else "FAIL"
    print(f"<== {path.stem}: {status} in {elapsed:.1f}s", flush=True)
    if not result["ok"]:
        print(f"    error: {result.get('error')}")
        print("    ---- last 60 lines of crash.log ----")
        for line in log_text.splitlines()[-60:]:
            print("    " + line)
    return result


def write_summary(out: Path, results: list, runtime_label: str) -> None:
    lines = [f"### WeRead emulator scenarios ({runtime_label})", "",
             "| Scenario | Result | Wall time | Steps | Key metrics |", "| --- | --- | --- | --- | --- |"]
    for result in results:
        steps = ", ".join(f"{step['name']} {step.get('ms', 0) / 1000:.1f}s" for step in result.get("steps", []))
        metrics = ", ".join(f"{key}={value}" for key, value in sorted(result.get("metrics", {}).items()))
        status = "✅ pass" if result["ok"] else "❌ " + str(result.get("error", "fail")).splitlines()[0][:160]
        lines.append(f"| `{result['scenario']}` {result.get('title', '')} | {status} | {result.get('wall_s', 0)}s "
                     f"| {steps or '-'} | {metrics or '-'} |")
    passed = sum(1 for result in results if result["ok"])
    lines += ["", f"**{passed}/{len(results)} passed.**"]
    (out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "summary.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--koreader", type=Path, help="KOReader runtime directory or tarball")
    parser.add_argument("--out", type=Path, default=Path(tempfile.gettempdir()) / "weread-emulator")
    parser.add_argument("--scenario", action="append", default=[], help="name prefix filter (repeatable)")
    parser.add_argument("--shard", default="", help="i/n: run every n-th scenario starting at i (1-based)")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--xvfb", action="store_true", help="use xvfb-run instead of SDL's dummy driver")
    parser.add_argument("--label", default="", help="runtime label for the summary")
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    args = parser.parse_args()
    scenarios = sorted(SCENARIO_DIR.glob("*.lua"))
    if args.scenario:
        scenarios = [s for s in scenarios if any(s.stem.startswith(prefix) for prefix in args.scenario)]
    if args.shard:
        # Longest-first onto the least-loaded shard, weighted by @timeout.
        index, count = (int(part) for part in args.shard.split("/"))
        loads = [0] * count
        assigned = {}
        for scenario in sorted(scenarios, key=lambda s: (-parse_meta(s)["timeout"], s.stem)):
            target = loads.index(min(loads))
            loads[target] += parse_meta(scenario)["timeout"]
            assigned[scenario] = target
        scenarios = [s for s in scenarios if assigned[s] == index - 1]
    if args.list:
        for scenario in scenarios:
            print(scenario.stem, "-", parse_meta(scenario)["title"])
        return 0
    if not scenarios:
        print("error: no scenarios selected", file=sys.stderr)
        return 2
    if not args.koreader:
        parser.error("--koreader is required")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    runtime = find_runtime(args.koreader, out)
    label = args.label
    if not label:
        label = (runtime / "git-rev").read_text().strip() if (runtime / "git-rev").is_file() else "KOReader"
    print(f"KOReader runtime: {runtime} ({label})", flush=True)
    candidate = build_candidate(out)
    results = [run_scenario(path, runtime, candidate, out, args) for path in scenarios]
    write_summary(out, results, label)
    print((out / "summary.md").read_text(encoding="utf-8"))
    return 0 if all(result["ok"] for result in results) else 1


if __name__ == "__main__":
    sys.exit(main())
