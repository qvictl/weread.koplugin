#!/usr/bin/env python3
"""Offline regression tests for coverage artifact selection after reruns."""

import io
import json
import os
from pathlib import Path
import subprocess
import textwrap
import tempfile
import unittest
from unittest import mock
import zipfile

import download_emulator_coverage as dc


COMMIT = "a" * 40


def artifact(ident, shard, created="2026-10-29T03:36:00Z", expired=False):
    return {"id": ident, "name": dc.SHARDS[shard - 1], "created_at": created, "expired": expired}


def archive(stats=b"2:main.lua\n1 0 \n", commit=COMMIT):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as result:
        if stats is not None:
            result.writestr("emulator.stats.out", stats)
        result.writestr("measured-commit.txt", commit + "\n")
    return data.getvalue()


class CoverageArtifactsTest(unittest.TestCase):
    def run_download(self, items, archives, directory):
        def api(endpoint, *_options):
            if endpoint.endswith("artifacts?per_page=100"):
                # API pages may contain arbitrary artifact ordering.
                return json.dumps([{"artifacts": items[:2]}, {"artifacts": items[2:]}]).encode()
            return archives[int(endpoint.split("/")[-2])]
        with mock.patch.object(dc, "gh_api", side_effect=api) as request:
            dc.download("owner/plugin", 123, directory)
        return request

    def test_rerun_uses_new_stats_instead_of_old_metadata_despite_lower_id(self):
        old = artifact(900, 1, "2026-10-29T03:34:58Z")
        new = artifact(100, 1, "2026-10-29T03:43:16Z")
        expired = artifact(999, 1, "2026-10-29T03:50:00Z", expired=True)
        items = [old, artifact(200, 2), expired, artifact(300, 3), new]
        archives = {900: archive(stats=None), 100: archive(), 200: archive(), 300: archive()}
        for order in [items, list(reversed(items))]:
            with self.subTest(order=[item["id"] for item in order]), tempfile.TemporaryDirectory() as directory:
                request = self.run_download(order, archives, directory)
                for name in dc.SHARDS:
                    self.assertEqual((Path(directory) / name / "emulator.stats.out").read_bytes(), b"2:main.lua\n1 0 \n")
                endpoints = [call.args[0] for call in request.call_args_list]
                self.assertFalse(any("/900/" in endpoint or "/999/" in endpoint for endpoint in endpoints))

    def test_missing_shard_cannot_produce_partial_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "Missing coverage shards"):
                self.run_download([artifact(100, 1), artifact(200, 2)], {}, directory)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_ambiguous_newest_timestamp_is_rejected(self):
        items = [artifact(100, 1), artifact(101, 1), artifact(200, 2), artifact(300, 3)]
        with self.assertRaisesRegex(ValueError, "Ambiguous coverage artifacts"):
            dc.select_artifacts(items)

    def test_older_timestamp_tie_does_not_hide_the_unique_newest_artifact(self):
        items = [artifact(100, 1), artifact(101, 1), artifact(200, 2), artifact(300, 3),
                 artifact(50, 1, "2026-10-29T03:50:00Z")]
        self.assertEqual(dc.select_artifacts(items)[dc.SHARDS[0]]["id"], 50)

    def test_newest_metadata_only_artifact_cannot_fall_back_to_older_stats(self):
        items = [artifact(100, 1), artifact(90, 1, "2026-10-29T03:35:00Z"),
                 artifact(200, 2), artifact(300, 3)]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(KeyError):
                self.run_download(items, {100: archive(stats=None), 90: archive()}, directory)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_mixed_measured_commits_cannot_produce_partial_coverage(self):
        items = [artifact(100, 1), artifact(200, 2), artifact(300, 3)]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "different commits"):
                self.run_download(items, {100: archive(), 200: archive(), 300: archive(commit="b" * 40)}, directory)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_empty_stats_and_invalid_commit_are_rejected(self):
        items = [artifact(100, 1), artifact(200, 2), artifact(300, 3)]
        for invalid in [archive(stats=b""), archive(commit="not-a-sha")]:
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError, "Invalid coverage"):
                    self.run_download(items, {100: invalid}, directory)
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_workflow_tooling_is_isolated_from_an_older_or_modified_pr_head(self):
        workflows = Path(__file__).resolve().parent.parent / ".github/workflows"
        commands = []
        for name in ["pr-policy.yml", "coverage.yml"]:
            source = (workflows / name).read_text()
            step = source.split("- name: Checkout coverage tooling\n", 1)[1].split("\n      - name:", 1)[0]
            commands.append(textwrap.dedent(step.split("run: |\n", 1)[1]))
        self.assertEqual(commands[0], commands[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repository), *args], text=True).strip()
            git("init", "--quiet")
            (repository / "old.txt").write_text("historical source has no downloader\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "old head")
            historical = git("rev-parse", "HEAD")
            script = repository / "scripts/download_emulator_coverage.py"
            script.parent.mkdir()
            script.write_text("# trusted workflow tooling\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "workflow tooling")
            workflow_sha = git("rev-parse", "HEAD")
            script.write_text("# arbitrary PR head tooling must not run\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "modified head")
            for head in [historical, git("rev-parse", "HEAD")]:
                with self.subTest(head=head), tempfile.TemporaryDirectory() as run_temp:
                    environment = dict(os.environ, GITHUB_REPOSITORY="owner/plugin", GITHUB_WORKFLOW_SHA=workflow_sha,
                                       GITHUB_SHA=head, RUNNER_TEMP=run_temp, GIT_CONFIG_COUNT="1",
                                       GIT_CONFIG_KEY_0=f"url.{repository.as_uri()}.insteadOf",
                                       GIT_CONFIG_VALUE_0="https://github.com/owner/plugin.git")
                    subprocess.run(["bash", "-e", "-c", commands[0]], env=environment, check=True, capture_output=True)
                    tooling = Path(run_temp) / "coverage-tooling"
                    self.assertEqual((tooling / "scripts/download_emulator_coverage.py").read_text(), "# trusted workflow tooling\n")
                    self.assertFalse((tooling / "old.txt").exists())

    def test_publisher_accepts_historical_main_but_rejects_unmerged_sources(self):
        workflow = Path(__file__).resolve().parent.parent / ".github/workflows/coverage.yml"
        source = workflow.read_text()
        step = source.split("- name: Validate measured main ancestry\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(step.split("run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repository), *args], text=True).strip()
            git("init", "--quiet", "--initial-branch=main")
            path = repository / "fixture.txt"
            revisions = []
            for value in ["historical main", "current main"]:
                path.write_text(value)
                git("add", ".")
                git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", value)
                revisions.append((git("rev-parse", "HEAD"), True))
            git("checkout", "--quiet", "-b", "feature")
            for value in ["feature source", "pull request source"]:
                path.write_text(value)
                git("add", ".")
                git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", value)
                revisions.append((git("rev-parse", "HEAD"), False))
            git("remote", "add", "origin", repository.as_uri())
            for revision, accepted in revisions:
                with self.subTest(revision=revision, accepted=accepted):
                    git("checkout", "--quiet", "--detach", revision)
                    result = subprocess.run(["bash", "-e", "-c", command], cwd=repository, capture_output=True)
                    self.assertEqual(result.returncode == 0, accepted)
                    if not accepted:
                        self.assertIn(b"not an ancestor of main", result.stdout)


if __name__ == "__main__":
    unittest.main()
