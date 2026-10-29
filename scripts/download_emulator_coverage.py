#!/usr/bin/env python3
"""Download each shard's newest coverage artifact, including rerun replacements."""

import argparse
import io
import json
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


def require_release_history(repo, run_id, target_sha, history, current_gate, cwd=None):
    """A failed publisher cannot silently drop an earlier accepted gate's floor."""
    from coverage_tools import read_history
    records = read_history(history, strict=True)
    candidate = json.loads(Path(current_gate).read_text())
    if candidate.get("passed") is not True or candidate.get("measured_sha") != target_sha:
        raise ValueError("Current release gate evidence is inconsistent")
    pages = json.loads(gh_api(
        f"repos/{repo}/actions/workflows/release.yml/runs?branch=main&per_page=100", "--paginate", "--slurp"))
    for run in (run for page in pages for run in page["workflow_runs"]):
        if run.get("conclusion") == "success" or run.get("event") == "pull_request":
            continue
        jobs = json.loads(gh_api(
            f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=all&per_page=100", "--paginate", "--slurp"))
        if not any(job.get("name") == "Release combined coverage gate" and job.get("conclusion") == "success"
                   for page in jobs for job in page["jobs"]):
            continue  # An unsuccessful integration/gate established no accepted combined floor.
        manifest = release_manifest(repo, run["id"])
        if not manifest["candidate"]:
            raise ValueError("A successful release gate has no candidate")
        sha = manifest.get("target_sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("Invalid earlier release candidate")
        ancestry = subprocess.run(["git", "merge-base", "--is-ancestor", sha, target_sha], cwd=cwd, capture_output=True)
        if ancestry.returncode == 1:
            continue  # A manually revalidated old candidate is not judged against its descendants.
        if ancestry.returncode != 0:
            raise ValueError("Cannot resolve earlier release ancestry")
        measured = []
        for artifact in artifacts_for_run(repo, run["id"]):
            if artifact["name"] != "release-coverage" or artifact.get("expired"):
                continue
            raw = gh_api(f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", "--allow-escape-sequences")
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                gate = json.loads(archive.read("release-gate.json"))
            if gate.get("mode") != "release" or gate.get("passed") is not True or gate.get("measured_sha") != sha:
                continue
            percent = gate.get("overall_combined", {}).get("percent")
            if type(percent) not in (int, float) or not 0 <= percent <= 100:
                raise ValueError("Invalid earlier combined measurement")
            measured.append(percent)
        if not measured:
            raise ValueError("Earlier accepted gate evidence is missing or inconsistent; restore that candidate's evidence")
        floor = max(measured)
        if any(record["sha"] == sha and record.get("combined", {}).get("percent", -1) >= floor
               for record in records):
            continue
        # Revalidating the same candidate can repair its failed publication,
        # but must retain every accepted earlier attempt's genuine floor.
        current = candidate.get("overall_combined", {}).get("percent")
        if sha == target_sha and type(current) in (int, float) and floor <= current <= 100:
            continue
        raise ValueError(f"Release {run['id']} passed its gate but its combined floor is not persisted; rerun that candidate first")


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
    parser.add_argument("--current-gate", help="current accepted release gate for same-candidate repair")
    parser.add_argument("--require-release-history", help="reject earlier accepted but unpersisted release gates")
    args = parser.parse_args()
    if args.require_release_history:
        if not args.expected_sha or not args.current_gate:
            parser.error("--require-release-history needs --expected-sha and --current-gate")
        require_release_history(args.repo, args.run, args.expected_sha, args.require_release_history, args.current_gate)
    elif args.source_out:
        Path(args.source_out).write_text(json.dumps(source(args.repo, args.run)) + "\n", encoding="utf-8")
    elif args.out:
        download(args.repo, args.run, args.out, args.expected_sha)
    else:
        parser.error("--out or --source-out is required")


if __name__ == "__main__":
    main()
