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
        artifact = select_artifacts(artifacts_for_run(repo, run_id), ("release-candidate",))["release-candidate"]
        raw = gh_api(f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", "--allow-escape-sequences")
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            manifest = json.loads(archive.read("candidate.json"))
        if manifest.get("run_id") != int(run_id) or type(manifest.get("candidate")) is not bool:
            raise ValueError("Release candidate manifest does not belong to this run")
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
    args = parser.parse_args()
    if args.source_out:
        Path(args.source_out).write_text(json.dumps(source(args.repo, args.run)) + "\n", encoding="utf-8")
    elif args.out:
        download(args.repo, args.run, args.out, args.expected_sha)
    else:
        parser.error("--out or --source-out is required")


if __name__ == "__main__":
    main()
