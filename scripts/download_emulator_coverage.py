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


def select_artifacts(artifacts):
    candidates = {}
    for artifact in artifacts:
        name = artifact["name"]
        if name not in SHARDS or artifact.get("expired"):
            continue
        candidates.setdefault(name, []).append(artifact)
    missing = set(SHARDS) - candidates.keys()
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


def download(repo, run_id, output):
    pages = json.loads(gh_api(
        f"repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100", "--paginate", "--slurp"
    ))
    selected = select_artifacts(artifact for page in pages for artifact in page["artifacts"])
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
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    download(args.repo, args.run, args.out)


if __name__ == "__main__":
    main()
