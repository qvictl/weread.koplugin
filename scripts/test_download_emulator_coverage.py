#!/usr/bin/env python3
"""Offline regression tests for coverage artifact selection after reruns."""

import io
import json
import os
import shutil
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
        for name in ["pr-policy.yml", "coverage.yml", "release.yml"]:
            source = (workflows / name).read_text()
            for part in source.split("- name: Checkout coverage tooling\n")[1:]:
                step = part.split("\n      - name:", 1)[0]
                commands.append(textwrap.dedent(step.split("run: |\n", 1)[1]))
        self.assertTrue(all(command == commands[0] for command in commands[1:]))
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


    def test_release_persists_real_reports_and_rechecks_a_racing_higher_floor(self):
        from test_coverage_tools import luacov_report, POLICY
        workflow = Path(__file__).resolve().parent.parent / ".github/workflows/release.yml"
        step = workflow.read_text().split("- name: Persist main measurement before publication\n", 1)[1].split("\n  package-and-release:", 1)[0]
        command = textwrap.dedent(step.split("run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, remote, seed = [root / name for name in ("source", "remote.git", "seed")]
            source.mkdir()
            def git(repo, *args):
                return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
            git(root, "init", "-q", "--bare", str(remote))
            git(source, "init", "-q", "-b", "main")
            (source / ".ci").mkdir()
            (source / ".ci/coverage-policy.json").write_text(json.dumps(dict(POLICY, diff_unit_min=80, diff_combined_min=90)))
            module = source / "weread/lib/m.lua"
            module.parent.mkdir(parents=True)
            rows = ["line_%d()" % i for i in range(20)]
            def commit():
                module.write_text("\n".join(rows) + "\n")
                git(source, "add", ".")
                git(source, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "source")
                return git(source, "rev-parse", "HEAD")
            base = commit()
            rows[0] = "candidate_A()"
            candidate = commit()
            git(source, "remote", "add", "origin", str(remote))
            git(source, "push", "-q", "origin", "main")
            git(root, "clone", "-q", str(remote), str(seed))
            git(seed, "checkout", "-q", "--orphan", "coverage")
            (seed / "history.jsonl").write_text(json.dumps({"sha": base, "date": "2026-10-28", "run": "", "unit": {"percent": 80}, "combined": {"percent": 90}}) + "\n")
            git(seed, "add", ".")
            git(seed, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "history")
            git(seed, "push", "-q", "origin", "coverage")
            run = root / "run"
            reports = run / "accepted-coverage"
            tools = run / "coverage-tooling/scripts"
            reports.mkdir(parents=True)
            tools.mkdir(parents=True)
            (tools / "coverage_tools.py").symlink_to(Path(__file__).resolve().parent / "coverage_tools.py")
            binaries = root / "bin"
            binaries.mkdir()
            (binaries / "sleep").write_text("#!/bin/sh\nexit 0\n")
            (binaries / "sleep").chmod(0o755)
            (binaries / "git").write_text('#!/bin/sh\nif [ "$REJECT_COVERAGE_PUSH" = 1 ]; then\n for arg do [ "$arg" != push ] || exit 9; done\nfi\nexec "' + shutil.which("git") + '" "$@"\n')
            (binaries / "git").chmod(0o755)
            env = dict(os.environ, RUNNER_TEMP=str(run), COVERAGE_REPO=str(source), SHA=candidate,
                       RUN_URL="https://example.invalid/runs/10", PATH=str(binaries) + os.pathsep + os.environ["PATH"])
            def measure(sha, missed):
                (reports / "unit.report.out").write_text(luacov_report({"weread/lib/m.lua": [(1, row) for row in rows]}))
                (reports / "combined.report.out").write_text(luacov_report({"weread/lib/m.lua": [(0 if i in missed else 1, row) for i,row in enumerate(rows)]}))
                (reports / "release-gate.json").write_text(json.dumps(dict(mode="release", passed=True, measured_sha=sha)))
                env["SHA"] = sha
                return subprocess.run(["bash", "-e", "-c", command], cwd=source, env=env, capture_output=True, text=True)
            env["REJECT_COVERAGE_PUSH"] = "1"
            result = measure(candidate, [19])
            self.assertNotEqual(result.returncode, 0, "a failed history push completed publication")
            records = [json.loads(line) for line in git(remote, "show", "coverage:history.jsonl").splitlines()]
            self.assertNotIn(candidate, [r["sha"] for r in records])
            env["REJECT_COVERAGE_PUSH"] = "0"
            result = measure(candidate, [19])
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            records = [json.loads(line) for line in git(remote, "show", "coverage:history.jsonl").splitlines()]
            self.assertEqual(next(r["combined"]["percent"] for r in records if r["sha"] == candidate), 95)
            rows[1] = "candidate_B()"
            next_candidate = commit()
            git(source, "push", "-q", "origin", "main")
            result = measure(next_candidate, [18,19])
            self.assertNotEqual(result.returncode, 0, "a newly persisted higher floor was ignored")
            self.assertIn("95.00%", result.stdout)
            records = [json.loads(line) for line in git(remote, "show", "coverage:history.jsonl").splitlines()]
            self.assertNotIn(next_candidate, [r["sha"] for r in records])

    def test_failed_release_persistence_cannot_drop_an_accepted_ancestor_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
            git("init", "-q")
            shas = []
            for value in ["A", "B"]:
                (root / "source").write_text(value)
                git("add", ".")
                git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", value)
                shas.append(git("rev-parse", "HEAD"))
            ancestor, target = shas
            history = root / "history.jsonl"
            def persist(percent=None):
                record = {"sha": ancestor, "unit": {"percent": 80}}
                if percent is not None:
                    record["combined"] = {"percent": percent}
                history.write_text(json.dumps(record) + "\n")
            gate = dict(mode="release", passed=True, measured_sha=ancestor, overall_combined={"percent": 95})
            manifest = dict(run_id=10, candidate=True, target_sha=ancestor, ci_run=9)
            current_gate = root / "current-gate.json"
            current_gate.write_text(json.dumps(dict(passed=True, measured_sha=target, overall_combined={"percent": 90})))
            gate_succeeded = True
            evidence_expired = False
            def zipped(name, value):
                output = io.BytesIO()
                with zipfile.ZipFile(output, "w") as archive:
                    archive.writestr(name, json.dumps(value))
                return output.getvalue()
            def api(endpoint, *_):
                if "/workflows/release.yml/runs?" in endpoint:
                    return json.dumps([{"workflow_runs": [
                        {"id": 20, "conclusion": None}, {"id": 5, "conclusion": "success"}]},
                        {"workflow_runs": [{"id": 10, "conclusion": "failure"}]}]).encode()
                if "/20/jobs?" in endpoint:
                    return json.dumps([{"jobs": []}]).encode()
                if "/10/jobs?" in endpoint:
                    return json.dumps([{"jobs": [{"name": "unrelated job", "conclusion": "success"}]},
                        {"jobs": [{"name": "Release combined coverage gate",
                        "conclusion": "success" if gate_succeeded else "failure"}]}]).encode()
                if "/10/artifacts?" in endpoint:
                    return json.dumps([{"artifacts": [
                        {"id": 100, "name": "release-candidate", "created_at": "2026-10-29T00:00:00Z"},
                        {"id": 101, "name": "release-coverage", "created_at": "2026-10-29T00:00:00Z", "expired": evidence_expired}]},
                        {"artifacts": [{"id": 102, "name": "release-coverage", "created_at": "2026-10-29T01:00:00Z", "expired": evidence_expired}]}]).encode()
                if "/100/zip" in endpoint:
                    return zipped("candidate.json", manifest)
                if "/101/zip" in endpoint:
                    return zipped("release-gate.json", gate)
                if "/102/zip" in endpoint:
                    return zipped("release-gate.json", dict(gate, overall_combined={"percent": 94}))
                self.fail("Unexpected endpoint: " + endpoint)
            with mock.patch.object(dc, "gh_api", side_effect=api):
                for percent in [None, 94]:
                    persist(percent)
                    with self.subTest(persisted=percent), self.assertRaisesRegex(ValueError, "not persisted"):
                        dc.require_release_history("owner/plugin", 20, target, history, current_gate, cwd=root)
                for percent in [95, 96]:
                    persist(percent)
                    dc.require_release_history("owner/plugin", 20, target, history, current_gate, cwd=root)
                persist(95)
                evidence_expired = True
                with self.assertRaisesRegex(ValueError, "missing or inconsistent"):
                    dc.require_release_history("owner/plugin", 20, target, history, current_gate, cwd=root)
                evidence_expired = False
                persist()
                with self.assertRaisesRegex(ValueError, "not persisted"):
                    dc.require_release_history("owner/plugin", 5, target, history, current_gate, cwd=root)
                gate_succeeded = False
                dc.require_release_history("owner/plugin", 20, target, history, current_gate, cwd=root)
                gate_succeeded = True
                current_gate.write_text(json.dumps(dict(passed=True, measured_sha=ancestor, overall_combined={"percent": 96})))
                dc.require_release_history("owner/plugin", 20, ancestor, history, current_gate, cwd=root)
                dc.require_release_history("owner/plugin", 10, ancestor, history, current_gate, cwd=root)
                current_gate.write_text(json.dumps(dict(passed=True, measured_sha=ancestor, overall_combined={"percent": 94})))
                with self.assertRaisesRegex(ValueError, "not persisted"):
                    dc.require_release_history("owner/plugin", 10, ancestor, history, current_gate, cwd=root)
                manifest["target_sha"] = target
                gate["measured_sha"] = target
                # Revalidating old A must not acquire a floor from its descendant B.
                dc.require_release_history("owner/plugin", 20, ancestor, history, current_gate, cwd=root)
                current_gate.write_text(json.dumps(dict(passed=True, measured_sha=target, overall_combined={"percent": 96})))
                manifest["target_sha"] = ancestor
                gate["measured_sha"] = target
                with self.assertRaisesRegex(ValueError, "inconsistent"):
                    dc.require_release_history("owner/plugin", 20, target, history, current_gate, cwd=root)

    def test_integration_records_the_candidate_when_caller_main_advanced(self):
        workflow = Path(__file__).resolve().parent.parent / ".github/workflows/integration.yml"
        step = workflow.read_text().split("- name: Record the measured commit\n", 1)[1].split("\n      - name:", 1)[0]
        declared = next(line.split("MEASURED_SHA:", 1)[1].strip() for line in step.splitlines() if "MEASURED_SHA:" in line)
        command = textwrap.dedent(step.split("run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            repository.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repository), *args], text=True).strip()
            git("init", "-q")
            revisions = []
            for value in ["candidate", "newer caller workflow"]:
                (repository / "fixture").write_text(value)
                git("add", ".")
                git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", value)
                revisions.append(git("rev-parse", "HEAD"))
            candidate, caller = revisions
            context = {"${{ inputs.target_sha }}": candidate, "${{ github.sha }}": caller}
            git("checkout", "-q", "--detach", candidate)
            output = Path(directory) / "output"
            env = dict(os.environ, OUT=str(output), MEASURED_SHA=context[declared], GITHUB_SHA=caller)
            result = subprocess.run(["bash", "-e", "-c", command], cwd=repository, env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / "coverage/measured-commit.txt").read_text().strip(), candidate)
            git("checkout", "-q", "--detach", caller)
            env["OUT"] = str(Path(directory) / "mismatch")
            result = subprocess.run(["bash", "-e", "-c", command], cwd=repository, env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0, "different checkout was labelled as the candidate")

    def test_release_requires_real_history_fetch_but_accepts_unit_only_history(self):
        workflow = Path(__file__).resolve().parent.parent / ".github/workflows/release.yml"
        step = workflow.read_text().split("- name: Fetch authentic coverage history\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(step.split("run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            repository.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repository), *args], text=True,
                                               stderr=subprocess.DEVNULL).strip()
            def commit(title):
                git("add", ".")
                git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", title)
            git("init", "-q", "--initial-branch=main")
            (repository / "fixture").write_text("main")
            commit("main")
            git("checkout", "-qb", "coverage")
            history = repository / "history.jsonl"
            history.write_text(json.dumps(dict(sha=COMMIT, unit=dict(percent=80))) + "\n")
            commit("unit-only coverage")
            git("checkout", "-q", "main")
            git("remote", "add", "origin", repository.as_uri())
            def run(label):
                env = dict(os.environ, RUNNER_TEMP=str(Path(directory) / label))
                return subprocess.run(["bash", "-e", "-c", command], cwd=repository, env=env, capture_output=True)
            self.assertEqual(run("unit-only").returncode, 0)
            git("branch", "-D", "coverage")
            self.assertNotEqual(run("missing-branch").returncode, 0,
                                "history fetch failure was mistaken for the first combined release")
            git("checkout", "-qb", "coverage")
            history.write_text("")
            commit("empty history")
            git("checkout", "-q", "main")
            self.assertNotEqual(run("empty-history").returncode, 0)


class CoverageSourcesTest(unittest.TestCase):
    def run_source(self, run=None, manifest=None, ci=None):
        run = run or dict(path=".github/workflows/release.yml", conclusion="success", head_branch="main",
                          event="workflow_run", head_sha="b" * 40)
        if manifest is None:
            manifest = dict(run_id=123, candidate=True, target_sha=COMMIT, ci_run=777)
        if ci is None:
            ci = dict(path=".github/workflows/ci.yml", conclusion="success", head_branch="main",
                      event="push", head_sha=COMMIT)
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as result:
            result.writestr("candidate.json", json.dumps(manifest))
        def api(endpoint, *_options):
            if endpoint.endswith("/runs/123"):
                return json.dumps(run).encode()
            if endpoint.endswith("/runs/777"):
                return json.dumps(ci).encode()
            if endpoint.endswith("artifacts?per_page=100"):
                return json.dumps([{"artifacts": [dict(id=10, name="release-candidate", expired=False,
                                                     created_at="2026-10-29T03:36:00Z")]}]).encode()
            if endpoint.endswith("/artifacts/10/zip"):
                return data.getvalue()
            raise AssertionError(endpoint)
        with mock.patch.object(dc, "gh_api", side_effect=api):
            return dc.source("owner/plugin", 123)

    def test_release_uses_declared_old_candidate_when_main_advanced(self):
        self.assertEqual(self.run_source(), dict(measure=True, sha=COMMIT, combined=True))

    def test_daily_ci_and_historical_integration_keep_their_real_source(self):
        for name, combined in [("ci", False), ("integration", True)]:
            with self.subTest(workflow=name):
                run = dict(path=f".github/workflows/{name}.yml", conclusion="success",
                           head_branch="main", event="push", head_sha=COMMIT)
                self.assertEqual(self.run_source(run=run), dict(measure=True, sha=COMMIT, combined=combined))

    def test_missing_manifest_never_uses_the_outer_release_head(self):
        run = dict(path=".github/workflows/release.yml", conclusion="success", head_branch="main",
                   event="workflow_run", head_sha="b" * 40)
        def api(endpoint, *_options):
            if endpoint.endswith("/runs/123"):
                return json.dumps(run).encode()
            return json.dumps([{"artifacts": []}]).encode()
        with mock.patch.object(dc, "gh_api", side_effect=api), self.assertRaises(ValueError):
            dc.source("owner/plugin", 123)

    def test_non_candidate_release_does_not_create_coverage(self):
        self.assertEqual(self.run_source(manifest=dict(run_id=123, candidate=False)), dict(measure=False))

    def test_wrong_manifest_run_or_source_ci_cannot_relabel_coverage(self):
        for manifest in [dict(run_id=122, candidate=True, target_sha=COMMIT, ci_run=777),
                         dict(run_id=123, candidate="true", target_sha=COMMIT, ci_run=777),
                         dict(run_id=123, candidate=True, target_sha="b" * 40, ci_run=777)]:
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                self.run_source(manifest=manifest)
        for change in [dict(conclusion="failure"), dict(head_branch="feature"), dict(event="pull_request"),
                       dict(path=".github/workflows/other.yml")]:
            ci = dict(path=".github/workflows/ci.yml", conclusion="success", head_branch="main",
                      event="push", head_sha=COMMIT)
            ci.update(change)
            with self.subTest(ci=ci), self.assertRaises(ValueError):
                self.run_source(ci=ci)

    def test_pr_or_failed_workflow_never_publishes_main_measurements(self):
        for change in [dict(conclusion="failure"), dict(head_branch="feature"), dict(event="pull_request")]:
            run = dict(path=".github/workflows/ci.yml", conclusion="success", head_branch="main",
                       event="push", head_sha=COMMIT)
            run.update(change)
            with self.subTest(run=run), self.assertRaises(ValueError):
                self.run_source(run=run)

    def test_consistent_old_shards_cannot_satisfy_a_new_candidate(self):
        items = [artifact(100, 1), artifact(200, 2), artifact(300, 3)]
        def api(endpoint, *_options):
            if endpoint.endswith("artifacts?per_page=100"):
                return json.dumps([{"artifacts": items}]).encode()
            return archive()
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(dc, "gh_api", side_effect=api):
            with self.assertRaisesRegex(ValueError, "release candidate"):
                dc.download("owner/plugin", 123, directory, expected_sha="b" * 40)
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
