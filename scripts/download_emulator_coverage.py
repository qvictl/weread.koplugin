#!/usr/bin/env python3
"""Download each shard's newest coverage artifact, including rerun replacements."""

import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


SHARDS = tuple(f"coverage-emulator-shard-{index}" for index in range(1, 4))


def select_artifacts(artifacts, names=SHARDS):
    candidates = {}
    for artifact in artifacts:
        name = artifact["name"]
        if name not in names or artifact.get("expired"):
            continue
        candidates.setdefault(name, []).append(artifact)
    missing = set(names) - candidates.keys()
    if missing:
        raise ValueError(f"Missing coverage shards: {', '.join(sorted(missing))}")
    selected = {}
    for name, values in candidates.items():
        newest = max(value["created_at"] for value in values)
        latest = {value["id"]: value for value in values if value["created_at"] == newest}
        if len(latest) != 1:
            raise ValueError(f"Ambiguous coverage artifacts for {name}")
        selected[name] = next(iter(latest.values()))
    return selected


def gh_api(endpoint, *options):
    return subprocess.run(
        ["gh", "api", endpoint, *options], check=True, capture_output=True
    ).stdout


def artifacts_for_run(repo, run_id):
    pages = json.loads(gh_api(
        f"repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100", "--paginate", "--slurp"
    ))
    return [artifact for page in pages for artifact in page["artifacts"]]


def release_manifest(repo, run_id):
    artifact = select_artifacts(artifacts_for_run(repo, run_id), ("release-candidate",))["release-candidate"]
    raw = gh_api(f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", "--allow-escape-sequences")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        manifest = json.loads(archive.read("candidate.json"))
    if manifest.get("run_id") != int(run_id) or type(manifest.get("candidate")) is not bool:
        raise ValueError("Release candidate manifest does not belong to this run")
    return manifest


def accepted_attempts(repo, run_id):
    pages = json.loads(gh_api(
        f"repos/{repo}/actions/runs/{run_id}/jobs?filter=all&per_page=100", "--paginate", "--slurp"))
    attempts = {job.get("run_attempt") for page in pages for job in page["jobs"]
                if job.get("name", "").rsplit(" / ", 1)[-1] == "Release combined coverage gate"
                and job.get("conclusion") == "success"}
    if any(type(attempt) is not int or attempt <= 0 for attempt in attempts):
        raise ValueError("Accepted release attempt is unknown")
    return attempts


def accepted_archives(repo, run_id, sha, attempts):
    found = {attempt: [] for attempt in attempts}
    for artifact in artifacts_for_run(repo, run_id):
        if artifact["name"] != "release-coverage" or artifact.get("expired"):
            continue
        raw = gh_api(f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", "--allow-escape-sequences")
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            try:
                gate = json.loads(archive.read("release-gate.json"))
            except (KeyError, json.JSONDecodeError):
                continue  # Failed jobs may never reach the gate.
        attempt = gate.get("run_attempt")
        if (gate.get("mode") != "release" or gate.get("passed") is not True or gate.get("measured_sha") != sha
                or type(gate.get("run_id")) is not int or gate["run_id"] != int(run_id)
                or type(attempt) is not int or attempt not in attempts):
            continue
        found[attempt].append((artifact, gate, raw))
    if any(not reports for reports in found.values()):
        raise ValueError("Earlier accepted gate evidence is missing or inconsistent; restore that candidate's evidence")
    return found


def download_accepted(repo, run_id, output, expected_sha):
    attempts = accepted_attempts(repo, run_id)
    if not attempts:
        raise ValueError("This release has no accepted combined gate attempt")
    # A failed rerun's newer report must not hide the successful attempt.
    reports = accepted_archives(repo, run_id, expected_sha, {max(attempts)})[max(attempts)]
    latest = select_artifacts([item[0] for item in reports], ("release-coverage",))["release-coverage"]
    _, gate, raw = next(item for item in reports if item[0]["id"] == latest["id"])
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        files = {name: archive.read(name) for name in (
            "release-gate.json", "unit.report.out", "combined.report.out", "release-checks.json")}
    from coverage_tools import validate_release_checks
    checks = validate_release_checks(json.loads(files["release-checks.json"]))
    own = checks.get(str(run_id), {})
    if (own.get("attempt", 0) < max(attempts) or own.get("sha") != expected_sha
            or type(gate.get("overall_combined", {}).get("percent")) not in (int, float)
            or not 0 <= gate["overall_combined"]["percent"] <= own.get("combined", -1)):
        raise ValueError("Accepted release watermark does not match its measurement")
    if any(not content.strip() for content in files.values()):
        raise ValueError("Accepted coverage reports are incomplete")
    Path(output).mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (Path(output) / name).write_bytes(content)


def require_release_history(repo, run_id, target_sha, history, current_gate, cwd=None,
                            checks_out=None, current_attempt=1):
    """Only new run attempts need jobs/artifact queries; durable proofs survive expiry."""
    from coverage_tools import read_history, merge_release_checks, load_policy
    tolerance = float(load_policy().get("ratchet_tolerance_pp", 0))
    records = read_history(history, strict=True)
    known = merge_release_checks(*(record.get("release_checks", {}) for record in records))
    candidate = json.loads(Path(current_gate).read_text())
    current = candidate.get("overall_combined", {}).get("percent")
    if (candidate.get("passed") is not True or candidate.get("measured_sha") != target_sha
            or type(current) not in (int, float) or not 0 <= current <= 100):
        raise ValueError("Current release gate evidence is inconsistent")
    def enforce(sha, floor):
        ancestry = subprocess.run(["git", "merge-base", "--is-ancestor", sha, target_sha], cwd=cwd, capture_output=True)
        if ancestry.returncode == 1:
            return
        if ancestry.returncode != 0:
            raise ValueError("Cannot resolve earlier release ancestry")
        if current + tolerance < floor:
            raise ValueError("Current measurement is below the accepted floor beyond policy tolerance")
        if sha == target_sha:
            return
        if any(record["sha"] == sha and record.get("combined", {}).get("percent", -1) + tolerance >= floor for record in records):
            return
        raise ValueError("An accepted combined floor is not persisted; rerun that candidate first")
    pages = json.loads(gh_api(
        f"repos/{repo}/actions/workflows/release.yml/runs?branch=main&per_page=100", "--paginate", "--slurp"))
    checked = {}
    for run in (run for page in pages for run in page["workflow_runs"]):
        if run.get("event") == "pull_request":
            continue
        attempt = run.get("run_attempt")
        if type(attempt) is not int or attempt <= 0:
            raise ValueError("Release run attempt is unknown")
        key = str(run["id"])
        previous = known.get(key, {})
        if "sha" in previous:
            enforce(previous["sha"], previous["combined"])
        if run["id"] != int(run_id) and run.get("status") != "completed" and run.get("conclusion") is None:
            continue  # A queued resolver may later run a candidate at this same attempt.
        if previous.get("attempt", 0) >= attempt:
            continue
        accepted = accepted_attempts(repo, run["id"])
        missing = {value for value in accepted if value > previous.get("attempt", 0)}
        if not missing:
            checked[key] = dict(previous, attempt=attempt)
            continue
        manifest = release_manifest(repo, run["id"])
        sha = manifest.get("target_sha", "")
        if not manifest["candidate"] or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("Invalid earlier release candidate")
        reports = accepted_archives(repo, run["id"], sha, missing)
        measured = [item[1].get("overall_combined", {}).get("percent")
                    for values in reports.values() for item in values]
        if any(type(value) not in (int, float) or not 0 <= value <= 100 for value in measured):
            raise ValueError("Invalid earlier combined measurement")
        floor = max([previous.get("combined", 0), *measured])
        enforce(sha, floor)
        checked[key] = dict(attempt=attempt, sha=sha, combined=floor)
    own = merge_release_checks({str(run_id): known[str(run_id)]} if str(run_id) in known else {},
                               {str(run_id): dict(attempt=current_attempt, sha=target_sha, combined=current)})
    checked = merge_release_checks(checked, own)
    if checks_out:
        Path(checks_out).write_text(json.dumps(checked, indent=2) + "\n", encoding="utf-8")
    return checked


def source(repo, run_id):
    """Resolve a main measurement; a Release run's head is its workflow, not its candidate."""
    run = json.loads(gh_api(f"repos/{repo}/actions/runs/{run_id}"))
    if run.get("conclusion") != "success" or run.get("head_branch") != "main" or run.get("event") == "pull_request":
        raise ValueError("Coverage publication requires a successful main workflow run")
    path = run.get("path")
    if path in (".github/workflows/ci.yml", ".github/workflows/integration.yml"):
        sha = run["head_sha"]
        combined = path.endswith("/integration.yml")  # historical authentic runs remain backfillable.
    elif path == ".github/workflows/release.yml":
        manifest = release_manifest(repo, run_id)
        if not manifest["candidate"]:
            return dict(measure=False)
        sha = manifest.get("target_sha", "")
        ci_run = manifest.get("ci_run")
        if type(ci_run) is not int or ci_run <= 0:
            raise ValueError("Release candidate has no successful source CI run")
        ci = json.loads(gh_api(f"repos/{repo}/actions/runs/{ci_run}"))
        if (ci.get("path") != ".github/workflows/ci.yml" or ci.get("conclusion") != "success"
                or ci.get("head_branch") != "main" or ci.get("event") == "pull_request"
                or ci.get("head_sha") != sha):
            raise ValueError("Release candidate does not match successful main CI")
        combined = True
    else:
        raise ValueError("Unsupported coverage source workflow")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid measured source SHA")
    return dict(measure=True, sha=sha, combined=combined)


def download(repo, run_id, output, expected_sha=None):
    selected = select_artifacts(artifacts_for_run(repo, run_id))
    received = {}
    measured = set()
    for name in SHARDS:
        artifact = selected[name]
        data = gh_api(f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", "--allow-escape-sequences")
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            stats = archive.read("emulator.stats.out")
            commit = archive.read("measured-commit.txt").decode("ascii").strip()
        if not stats.strip() or not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError(f"Invalid coverage files in {name}")
        measured.add(commit)
        received[name] = stats, commit
        print(f"{name}: artifact {artifact['id']} created {artifact['created_at']}; {len(stats)} stats bytes")
    if len(measured) != 1:
        raise ValueError("Coverage shards measured different commits")
    if expected_sha is not None and measured != {expected_sha}:
        raise ValueError("Coverage shards do not match the release candidate")
    # Validate every shard before exposing any stats to the coverage merger.
    for name, (stats, commit) in received.items():
        directory = Path(output) / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "emulator.stats.out").write_bytes(stats)
        (directory / "measured-commit.txt").write_text(commit + "\n", encoding="ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--out")
    parser.add_argument("--expected-sha")
    parser.add_argument("--source-out", help="resolve CI/Release main measurement into JSON")
    parser.add_argument("--accepted-out", help="download the exact latest accepted release reports")
    parser.add_argument("--checks-out", help="durable checked run/attempt proof")
    parser.add_argument("--current-gate", help="current accepted release gate for same-candidate repair")
    parser.add_argument("--require-release-history", help="reject earlier accepted but unpersisted release gates")
    args = parser.parse_args()
    if args.require_release_history:
        if not args.expected_sha or not args.current_gate:
            parser.error("--require-release-history needs --expected-sha and --current-gate")
        require_release_history(args.repo, args.run, args.expected_sha, args.require_release_history, args.current_gate,
                                checks_out=args.checks_out, current_attempt=int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")))
    elif args.accepted_out:
        if not args.expected_sha:
            parser.error("--accepted-out needs --expected-sha")
        download_accepted(args.repo, args.run, args.accepted_out, args.expected_sha)
    elif args.source_out:
        Path(args.source_out).write_text(json.dumps(source(args.repo, args.run)) + "\n", encoding="utf-8")
    elif args.out:
        download(args.repo, args.run, args.out, args.expected_sha)
    else:
        parser.error("--out or --source-out is required")


if __name__ == "__main__":
    main()
