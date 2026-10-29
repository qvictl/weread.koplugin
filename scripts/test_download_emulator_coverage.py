#!/usr/bin/env python3
"""Offline regression tests for coverage artifact selection after reruns."""

import io
import json
from pathlib import Path
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
        items = [artifact(100, 1), artifact(200, 2), artifact(300, 3)]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(KeyError):
                self.run_download(items, {100: archive(stats=None)}, directory)
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


if __name__ == "__main__":
    unittest.main()
