#!/usr/bin/env python3
"""Unit tests of review_gate.py with mocked GitHub API responses.

    python3 -m unittest discover -s .github/review-gate -v
"""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.dont_write_bytecode = True  # keep .github/review-gate/ free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))
import review_gate as rg  # noqa: E402

REPO = "qvictl/demo"
HEAD = "a" * 40
OLD = "b" * 40

CONFIG: Dict[str, Any] = dict(rg.DEFAULT_CONFIG)
CONFIG.update({
    "merge_method": "SQUASH",
    "merge_method_overrides": [{"head_ref": "sync/upstream-*", "method": "MERGE"}],
    "max_changed_lines": 500,
    "test_paths": ["spec/**", "**/*_spec.lua", "scripts/test_*.py"],
    "doc_paths": ["**/*.md", "docs/**"],
    "sensitive_paths": [".github/**", ".ci/**", "REVIEW_POLICY.md", ".gemini/**", "weread/lib/updater.lua"],
    "sensitive_line_patterns": [
        {"path": "main.lua", "regex": "^\\s*version\\s*=", "description": "版本号"},
        {"path": "weread/lib/client.lua", "regex": "(?i)(cookie|token|auth)", "description": "认证"},
    ],
})


def review(login: str, state: str, commit: str = HEAD, rid: int = 1, at: str = "2026-10-27T10:00:00Z",
           body: str = "") -> Dict[str, Any]:
    return {"id": rid, "user": {"login": login}, "state": state, "commit_id": commit, "submitted_at": at,
            "body": body}


def check(name: str, conclusion: Optional[str] = "success", status: str = "completed", rid: int = 1,
          at: str = "2026-10-27T09:00:00Z") -> Dict[str, Any]:
    return {"id": rid, "name": name, "status": status, "conclusion": conclusion, "started_at": at,
            "app": {"id": 15368}}


class FakeGitHub(rg.GitHub):
    """Serves canned responses; records every write."""

    def __init__(self, state: Dict[str, Any]):
        super().__init__("token")
        self.s = state
        self.writes: List[tuple] = []
        self.fail: Dict[str, int] = {}

    def _route(self, path: str) -> Any:
        s = self.s
        path = path.split("?")[0]
        n = s["pr"]["number"]
        for prefix, status in self.fail.items():
            if path.startswith(prefix):
                raise rg.ApiError(status, "forced")
        if path == "repos/%s" % REPO:
            return s["repo"]
        if path == "repos/%s/pulls/%d" % (REPO, n):
            return s["pr"]
        if path.startswith("repos/%s/branches/" % REPO):
            return s["branch"]
        if path.endswith("/check-runs"):
            return {"check_runs": s["check_runs"]}
        if path.endswith("/statuses"):
            return s["statuses"]
        if path == "repos/%s/pulls/%d/reviews" % (REPO, n):
            return s["reviews"]
        if path == "repos/%s/pulls/%d/files" % (REPO, n):
            return s["files"]
        if path == "repos/%s/issues/%d/comments" % (REPO, n):
            return s["comments"]
        if path == "repos/%s/issues/%d/events" % (REPO, n):
            return s["events"]
        if path.startswith("repos/%s/collaborators/" % REPO):
            user = path.split("/")[4]
            return {"role_name": s["roles"].get(user, "none"), "permission": s["roles"].get(user, "none")}
        if path == "search/issues":
            return {"total_count": s["merged_prs"]}
        if path.endswith("/check-suites"):
            return {"check_suites": s.get("suites", [{"created_at": "2026-10-27T08:00:00Z"}])}
        if path.startswith("repos/%s/commits/" % REPO) and path.endswith("/pulls"):
            return s.get("commit_pulls", [])
        if path == "repos/%s/pulls" % REPO:
            return [s["pr"]]
        raise AssertionError("unexpected GET " + path)

    def get(self, path: str) -> Any:
        return copy.deepcopy(self._route(path))

    def get_all(self, path: str, key: Optional[str] = None, limit: int = 3000) -> List[Any]:
        data = self.get(path)
        return (data[key] if key else data)[:limit]

    def request(self, method: str, path: str, body: Any = None) -> Any:
        if method == "GET":
            return self.get(path)
        for prefix, status in self.fail.items():
            if path.startswith(prefix):
                raise rg.ApiError(status, "forced")
        self.writes.append((method, path, body))
        return {}

    def graphql(self, query: str, variables: Dict[str, Any]) -> Any:
        if "mutation" in query and self.s.get("enable_error") and "enablePullRequestAutoMerge" in query:
            raise rg.ApiError(200, self.s["enable_error"])
        if "mutation" in query:
            kind = "enable" if "enablePullRequestAutoMerge" in query else "disable"
            self.writes.append(("GRAPHQL", kind, variables))
            return {}
        return {"repository": {"pullRequest": {
            "id": "PR_node", "autoMergeRequest": self.s["auto_merge"],
            "reviewThreads": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                              "nodes": self.s["threads"]}}}}


def base_state() -> Dict[str, Any]:
    """A PR that satisfies every condition."""
    return {
        "repo": {"owner": {"login": "qvictl"}, "default_branch": "main", "allow_auto_merge": True},
        "pr": {"number": 7, "state": "open", "draft": False, "node_id": "PR_node",
               "head": {"sha": HEAD, "ref": "fix/thing"}, "base": {"ref": "main"},
               "user": {"login": "qvictl", "type": "User"}, "author_association": "OWNER",
               "labels": [], "changed_files": 2},
        "branch": {"protection": {"required_status_checks": {
            "contexts": ["ci", "tests-policy"],
            "checks": [{"context": "ci", "app_id": 15368}, {"context": "tests-policy", "app_id": 15368}]}}},
        "check_runs": [check("ci", rid=1), check("tests-policy", rid=2), check("optional", "failure", rid=3)],
        "statuses": [],
        "reviews": [review("coderabbitai[bot]", "APPROVED")],
        "threads": [{"isResolved": True, "isOutdated": False, "path": "a.lua",
                     "comments": {"nodes": [{"author": {"login": "coderabbitai"}, "url": "u"}]}}],
        "files": [{"filename": "weread/lib/thing.lua", "additions": 10, "deletions": 2, "patch": "+x\n-y"},
                  {"filename": "spec/thing_spec.lua", "additions": 900, "deletions": 0, "patch": "+t"}],
        "comments": [],
        "events": [],
        "roles": {},
        "merged_prs": 0,
        "auto_merge": None,
    }


class GateCase(unittest.TestCase):
    def setUp(self) -> None:
        self.state = base_state()

    def run_gate(self, dry_run: bool = False, merge_token: bool = True):
        gh = FakeGitHub(self.state)
        merge_gh = gh if merge_token else None
        facts = rg.collect(gh, REPO, 7)
        verdict = rg.evaluate(facts, CONFIG)
        actions, automerge_on = rg.apply(gh, merge_gh, facts, verdict, dry_run, log=lambda _m: None)
        body = rg.render(facts, verdict, automerge_on)
        result = rg.upsert_comment(gh, facts, body, dry_run)
        self.gh, self.verdict, self.body, self.result = gh, verdict, body, result
        return verdict

    def cond(self, key: str) -> rg.Condition:
        return next(c for c in self.verdict.conditions if c.key == key)

    def approved(self) -> bool:
        return any(w[0] == "POST" and w[1].endswith("/reviews") and w[2]["event"] == "APPROVE" for w in self.gh.writes)

    def automerge(self) -> Optional[str]:
        for w in self.gh.writes:
            if w[0] == "GRAPHQL":
                return w[1]
        return None

    def dismissed(self) -> List[str]:
        return [w[1] for w in self.gh.writes if w[0] == "PUT" and w[1].endswith("/dismissals")]


class GlobTest(unittest.TestCase):
    def test_patterns(self):
        self.assertTrue(rg.glob_to_regex(".github/**").match(".github/workflows/ci.yml"))
        self.assertTrue(rg.glob_to_regex("**/*.md").match("README.md"))
        self.assertTrue(rg.glob_to_regex("**/*.md").match("docs/a/b.md"))
        self.assertFalse(rg.glob_to_regex("*.md").match("docs/b.md"))
        self.assertTrue(rg.glob_to_regex("**/spec/**").match("plugins/x.koplugin/spec/a.lua"))
        self.assertFalse(rg.glob_to_regex("base").match("base/ffi/util.lua"))
        self.assertTrue(rg.glob_to_regex("base").match("base"))
        self.assertTrue(rg.glob_to_regex("sync/upstream-*").match("sync/upstream-20261027"))
        self.assertFalse(rg.glob_to_regex("weread/lib/updater.lua").match("weread/lib/updaterXlua"))
        self.assertTrue(rg.glob_to_regex("{frontend,plugins}/**/*.lua").match("plugins/kosync.koplugin/main.lua"))
        self.assertTrue(rg.glob_to_regex("{frontend,plugins}/**/*.lua").match("frontend/ui/a.lua"))
        self.assertFalse(rg.glob_to_regex("{frontend,plugins}/**/*.lua").match("spec/unit/a.lua"))
        self.assertTrue(rg.glob_to_regex("{.github,.ci}/**").match(".ci/x.sh"))


class HappyPathTest(GateCase):
    def test_all_conditions_hold_approves_and_enables_automerge(self):
        v = self.run_gate()
        self.assertTrue(v.ok, [c.detail for c in v.blockers])
        self.assertTrue(self.approved())
        approve = next(w for w in self.gh.writes if w[1].endswith("/reviews"))
        self.assertEqual(approve[2]["commit_id"], HEAD)
        self.assertIn(rg.APPROVAL_MARKER, approve[2]["body"])
        self.assertEqual(self.automerge(), "enable")
        enable = next(w for w in self.gh.writes if w[0] == "GRAPHQL")
        self.assertEqual(enable[2]["method"], "SQUASH")
        self.assertEqual(enable[2]["head"], HEAD)
        self.assertEqual(self.result, "created")
        self.assertTrue(self.body.startswith(rg.MARKER))
        self.assertIn(rg.AUTOMERGE_STATE, self.body)
        self.assertIn("满足全部条件", self.body)
        self.assertIn("网关批准并开启自动合并", self.body)

    def test_existing_valid_approval_is_not_repeated(self):
        self.state["reviews"].append(review("github-actions[bot]", "APPROVED", rid=9, body=rg.APPROVAL_MARKER))
        self.run_gate()
        self.assertFalse(self.approved())
        self.assertEqual(self.dismissed(), [])

    def test_no_merge_token_approves_without_automerge(self):
        self.run_gate(merge_token=False)
        self.assertTrue(self.approved())
        self.assertIsNone(self.automerge())
        self.assertIn("REVIEW_GATE_MERGE_TOKEN", self.body)
        self.assertFalse(self.verdict.defer_automerge)

    def test_automerge_is_deferred_to_the_token_job(self):
        gh = FakeGitHub(self.state)
        facts = rg.collect(gh, REPO, 7)
        verdict = rg.evaluate(facts, CONFIG)
        _actions, on = rg.apply(gh, None, facts, verdict, False, log=lambda _m: None, defer_automerge=True)
        self.assertTrue(verdict.defer_automerge)
        self.assertFalse(on)
        self.assertNotIn("REVIEW_GATE_MERGE_TOKEN", rg.render(facts, verdict, on))
        self.assertFalse(any(w[0] == "GRAPHQL" for w in gh.writes))

    def test_main_reports_ready_prs_and_automerge_job_enables(self):
        fake = FakeGitHub(self.state)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            old_env, old_cls = dict(os.environ), rg.GitHub
            os.environ.update({"GITHUB_TOKEN": "t", "GITHUB_OUTPUT": str(out), "REVIEW_GATE_AUTOMERGE": "on"})
            os.environ.pop("REVIEW_GATE_MERGE_TOKEN", None)
            rg.GitHub = lambda *_a, **_k: fake  # type: ignore
            try:
                rg.main(["--repo", REPO, "--pr", "7", "--summary", str(Path(tmp) / "s.md")])
                self.assertEqual(out.read_text().strip(), "automerge=7")
                self.assertFalse(any(w[0] == "GRAPHQL" for w in fake.writes))
                os.environ["REVIEW_GATE_MERGE_TOKEN"] = "m"
                rg.main(["--repo", REPO, "--prs", "7", "--summary", str(Path(tmp) / "s.md")])
                self.assertIn(("GRAPHQL", "enable"), [(w[0], w[1]) for w in fake.writes])
            finally:
                rg.GitHub = old_cls  # type: ignore
                os.environ.clear()
                os.environ.update(old_env)

    def test_clean_pr_is_merged_directly_at_the_evaluated_head(self):
        self.state["enable_error"] = '[{"message": "Pull request Pull request is in clean status"}]'
        self.run_gate()
        merge = [w for w in self.gh.writes if w[0] == "PUT" and w[1].endswith("/merge")]
        self.assertEqual(merge, [("PUT", "repos/%s/pulls/7/merge" % REPO, {"sha": HEAD, "merge_method": "squash"})])

    def test_unstable_pr_is_merged_directly(self):
        # Mergeable with a failing non-required check (seen on qvictl/koreader#12).
        self.state["enable_error"] = '[{"message": "Pull request Pull request is in unstable status"}]'
        self.run_gate()
        self.assertTrue(any(w[0] == "PUT" and w[1].endswith("/merge") and w[2]["sha"] == HEAD for w in self.gh.writes))

    def test_other_automerge_errors_are_reported(self):
        self.state["enable_error"] = "boom"
        self.run_gate()
        self.assertFalse(any(w[1].endswith("/merge") for w in self.gh.writes))
        self.assertIn("开启自动合并失败", self.body)

    def test_network_errors_become_api_errors(self):
        gh = rg.GitHub("t", "http://127.0.0.1:9")  # nothing listens on the discard port
        with self.assertRaises(rg.ApiError):
            gh.get("repos/x/y")

    def test_auto_merge_setting_not_visible_to_the_token(self):
        del self.state["repo"]["allow_auto_merge"]  # GITHUB_TOKEN does not see repository settings
        self.run_gate()
        self.assertEqual(self.automerge(), "enable")

    def test_repo_without_auto_merge_setting(self):
        self.state["repo"]["allow_auto_merge"] = False
        self.run_gate()
        self.assertTrue(self.approved())
        self.assertIsNone(self.automerge())
        self.assertIn("Allow auto-merge", self.body)

    def test_dry_run_writes_nothing(self):
        self.run_gate(dry_run=True)
        self.assertEqual(self.gh.writes, [])
        self.assertEqual(self.result, "dry-run")

    def test_unchanged_comment_is_not_rewritten(self):
        self.run_gate()
        body = self.body
        self.state["comments"] = [{"id": 5, "user": {"login": "github-actions[bot]"}, "body": body}]
        self.state["reviews"].append(review("github-actions[bot]", "APPROVED", rid=9, body=rg.APPROVAL_MARKER))
        self.state["auto_merge"] = {"mergeMethod": "SQUASH", "enabledBy": {"login": "qvictl"}}
        self.run_gate()
        self.assertEqual(self.gh.writes, [])

    def test_changed_comment_is_patched_and_foreign_marker_comments_ignored(self):
        self.state["comments"] = [{"id": 4, "user": {"login": "mallory"}, "body": rg.MARKER + " fake"},
                                  {"id": 5, "user": {"login": "github-actions[bot]"}, "body": rg.MARKER + " old"}]
        self.run_gate()
        self.assertEqual(self.result, "updated")
        self.assertIn(("PATCH", "repos/%s/issues/comments/5" % REPO), [(w[0], w[1]) for w in self.gh.writes])


class RequiredChecksTest(GateCase):
    def test_failed_required_check_blocks(self):
        self.state["check_runs"][0]["conclusion"] = "failure"
        v = self.run_gate()
        self.assertFalse(v.ok)
        self.assertIn("`ci`（failure）", self.cond("checks").detail)
        self.assertFalse(self.approved())

    def test_pending_and_missing_checks_block(self):
        self.state["check_runs"] = [check("ci", None, status="in_progress")]
        self.run_gate()
        c = self.cond("checks")
        self.assertFalse(c.ok)
        self.assertTrue(c.pending)
        self.assertIn("tests-policy`（尚未上报）", c.detail)

    def test_latest_rerun_wins(self):
        self.state["check_runs"] += [check("ci", "failure", rid=10, at="2026-10-27T08:00:00Z")]
        self.assertTrue(self.run_gate().ok)
        self.state["check_runs"] += [check("ci", "cancelled", rid=11, at="2026-10-27T11:00:00Z")]
        self.assertFalse(self.run_gate().ok)

    def test_queued_rerun_supersedes_older_success(self):
        self.state["check_runs"].append(check("ci", None, status="queued", rid=0, at=None))
        self.run_gate()
        self.assertFalse(self.cond("checks").ok)
        self.assertIn("`ci`（queued）", self.cond("checks").detail)

    def test_completed_run_without_started_at_does_not_hide_a_newer_failure(self):
        self.state["check_runs"] = [check("ci", "success", rid=1, at=None),
                                    check("ci", "failure", rid=2, at="2026-10-27T10:00:00Z"),
                                    check("tests-policy", rid=3)]
        self.run_gate()
        self.assertFalse(self.cond("checks").ok)
        self.assertIn("`ci`（failure）", self.cond("checks").detail)

    def test_check_from_another_app_does_not_count(self):
        self.state["check_runs"][0]["app"] = {"id": 1}
        self.assertFalse(self.run_gate().ok)

    def test_skipped_counts_as_passed_and_statuses_are_read(self):
        self.state["check_runs"][0]["conclusion"] = "skipped"
        self.state["branch"]["protection"]["required_status_checks"]["checks"].append({"context": "legacy", "app_id": None})
        self.state["statuses"] = [{"id": 1, "context": "legacy", "state": "success", "updated_at": "1"}]
        self.assertTrue(self.run_gate().ok)
        self.state["statuses"].append({"id": 2, "context": "legacy", "state": "failure", "updated_at": "2"})
        self.assertFalse(self.run_gate().ok)

    def test_unreadable_or_missing_protection_fails_closed(self):
        self.state["branch"] = {"protection": {}}
        self.assertFalse(self.run_gate().ok)
        self.state = base_state()
        gh = FakeGitHub(self.state)
        gh.fail["repos/%s/branches/" % REPO] = 403
        facts = rg.collect(gh, REPO, 7)
        self.assertFalse(rg.evaluate(facts, CONFIG).ok)


class AiReviewTest(GateCase):
    def test_no_ai_review_is_advisory_waiting(self):
        self.state["reviews"] = []
        v = self.run_gate()
        c = self.cond("ai")
        self.assertFalse(v.ok)
        self.assertTrue(c.pending)
        self.assertIn("咨询模式", c.detail)
        self.assertFalse(self.approved())
        self.assertIsNone(self.automerge())

    def test_review_of_older_commit_only(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "COMMENTED", commit=OLD)]
        self.run_gate()
        self.assertFalse(self.cond("ai").ok)
        self.assertIn("等待 AI 审查最新提交", self.cond("ai").detail)

    def test_gemini_comment_review_on_head_is_enough(self):
        self.state["reviews"] = [review("gemini-code-assist[bot]", "COMMENTED")]
        self.assertTrue(self.run_gate().ok)

    def cr_run(self, status="completed", conclusion="success",
               summary="Result: Success - Review completed\nRun ID: `x`", title="Finished", slug="coderabbitai"):
        return {"id": 50, "name": "CodeRabbit", "status": status, "conclusion": conclusion, "started_at": "z",
                "app": {"id": 347564, "slug": slug}, "output": {"title": title, "summary": summary}}

    def test_coderabbit_check_run_counts_when_no_review_was_posted(self):
        # Clean PR: CodeRabbit posts no review, only its check run (seen on qvictl/weread.koplugin#36).
        self.state["reviews"] = []
        self.state["check_runs"].append(self.cr_run())
        self.assertTrue(self.run_gate().ok)
        self.assertIn("CodeRabbit 已审查", self.cond("ai").detail)

    def test_coderabbit_check_run_in_progress_or_skipped(self):
        self.state["reviews"] = []
        self.state["check_runs"].append(self.cr_run(status="in_progress", conclusion=None))
        self.run_gate()
        self.assertFalse(self.cond("ai").ok)
        self.assertIn("正在审查", self.cond("ai").detail)
        self.state["check_runs"][-1] = self.cr_run(title="Review skipped", summary="Result: Success - Review completed")
        self.assertFalse(self.run_gate().ok)
        self.state["check_runs"][-1] = self.cr_run(conclusion="failure")
        self.assertFalse(self.run_gate().ok)
        self.state["check_runs"][-1] = self.cr_run(slug="impostor")
        self.assertFalse(self.run_gate().ok)

    def test_queued_coderabbit_run_supersedes_older_success(self):
        self.state["reviews"] = []
        old = self.cr_run()
        old["started_at"] = "2026-10-28T01:00:00Z"
        new = self.cr_run(status="queued", conclusion=None, summary="")
        new["started_at"], new["id"] = None, 1  # newer although its id is smaller
        self.state["check_runs"] += [old, new]
        self.run_gate()
        self.assertFalse(self.cond("ai").ok)
        self.assertFalse(self.verdict.ok)

    def test_newer_success_beats_older_failed_or_skipped_coderabbit_run(self):
        self.state["reviews"] = []
        old = self.cr_run(title="Review skipped")
        old["started_at"] = "2026-10-28T01:00:00Z"
        new = self.cr_run()
        new["started_at"] = "2026-10-28T02:00:00Z"
        self.state["check_runs"] += [old, new]
        self.assertTrue(self.run_gate().ok)

    def test_check_run_does_not_override_changes_requested(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "CHANGES_REQUESTED", commit=OLD)]
        self.state["check_runs"].append(self.cr_run())
        self.assertFalse(self.run_gate().ok)

    def test_human_review_does_not_count_as_ai(self):
        self.state["reviews"] = [review("someone", "APPROVED")]
        self.assertFalse(self.run_gate().ok)

    def test_changes_requested_blocks_even_if_other_ai_approves(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "CHANGES_REQUESTED", rid=1),
                                 review("gemini-code-assist[bot]", "COMMENTED", rid=2)]
        self.run_gate()
        self.assertFalse(self.cond("ai").ok)
        self.assertIn("Request changes", self.cond("ai").detail)

    def test_comment_after_changes_requested_still_blocks(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "CHANGES_REQUESTED", rid=1, at="1"),
                                 review("coderabbitai[bot]", "COMMENTED", rid=2, at="2")]
        self.assertFalse(self.run_gate().ok)

    def test_approval_after_changes_requested_unblocks(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "CHANGES_REQUESTED", commit=OLD, rid=1, at="1"),
                                 review("coderabbitai[bot]", "APPROVED", rid=2, at="2")]
        self.assertTrue(self.run_gate().ok)

    def test_dismissed_approval_still_proves_the_review(self):
        # The gate dismissed Gemini's approval while blocked; once unblocked it still counts.
        self.state["reviews"] = [review("gemini-code-assist[bot]", "DISMISSED")]
        self.assertTrue(self.run_gate().ok)

    def test_dismissed_changes_request_is_ignored(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "DISMISSED", rid=1, at="1"),
                                 review("coderabbitai[bot]", "COMMENTED", rid=2, at="2")]
        self.assertTrue(self.run_gate().ok)


class ThreadsTest(GateCase):
    def test_unresolved_thread_blocks_even_when_outdated(self):
        self.state["threads"].append({"isResolved": False, "isOutdated": True, "path": "x.lua",
                                      "comments": {"nodes": [{"author": {"login": "coderabbitai"}, "url": "U"}]}})
        self.run_gate()
        self.assertFalse(self.cond("threads").ok)
        self.assertIn("[x.lua](U) @coderabbitai", self.cond("threads").detail)
        self.assertFalse(self.approved())


class EligibilityTest(GateCase):
    def test_draft_blocks(self):
        self.state["pr"]["draft"] = True
        self.run_gate()
        self.assertFalse(self.cond("eligible").ok)
        self.assertIn("草稿", self.cond("eligible").detail)

    def test_do_not_merge_blocks(self):
        self.state["pr"]["labels"] = [{"name": "do-not-merge"}]
        v = self.run_gate()
        self.assertFalse(v.ok)
        self.assertFalse(self.approved())

    def test_sync_branch_uses_merge_commit_and_large_or_sensitive_changes_pass(self):
        # No size / sensitive-path / human rules any more (owner decision 2026-10-28).
        self.state["pr"]["head"]["ref"] = "sync/upstream-20261027"
        self.state["files"] = [{"filename": ".github/workflows/ci.yml", "additions": 5000, "deletions": 0}]
        v = self.run_gate()
        self.assertTrue(v.ok)
        self.assertEqual(v.merge_method, "MERGE")
        self.assertTrue(v.is_sync)

    def test_github_actions_sync_pr_cannot_be_self_approved(self):
        self.state["pr"]["user"] = {"login": "github-actions[bot]", "type": "Bot"}
        self.state["pr"]["author_association"] = "NONE"
        self.state["pr"]["head"]["ref"] = "sync/upstream-20261027"
        v = self.run_gate()
        self.assertFalse(v.ok)
        self.assertFalse(v.approvable)
        self.assertFalse(self.approved())
        self.assertIn("GitHub 不允许 github-actions 批准自己创建的 PR", self.body)
        self.assertIn("SYNC_TOKEN", self.body)


class DismissTest(GateCase):
    def test_new_commit_dismisses_old_approval_and_reapproves(self):
        self.state["reviews"].append(review("github-actions[bot]", "APPROVED", commit=OLD, rid=9,
                                            body=rg.APPROVAL_MARKER))
        self.run_gate()
        self.assertEqual(self.dismissed(), ["repos/%s/pulls/7/reviews/9/dismissals" % REPO])
        self.assertTrue(self.approved())

    def test_failing_condition_dismisses_and_disables_own_automerge(self):
        self.state["reviews"].append(review("github-actions[bot]", "APPROVED", rid=9, body=rg.APPROVAL_MARKER))
        self.state["threads"].append({"isResolved": False, "path": "p", "comments": {"nodes": []}})
        self.state["auto_merge"] = {"mergeMethod": "SQUASH", "enabledBy": {"login": "qvictl"}}
        self.state["comments"] = [{"id": 5, "user": {"login": "github-actions[bot]"},
                                   "body": rg.MARKER + "\n" + rg.AUTOMERGE_STATE}]
        self.run_gate()
        self.assertEqual(len(self.dismissed()), 2)  # the gate's and CodeRabbit's
        dismissal = next(w for w in self.gh.writes if w[1].endswith("/dismissals"))
        self.assertIn("没有未解决的审查对话", dismissal[2]["message"])
        self.assertEqual(self.automerge(), "disable")
        self.assertNotIn(rg.AUTOMERGE_STATE, self.body)

    def test_automerge_enabled_by_someone_else_is_left_alone(self):
        self.state["threads"].append({"isResolved": False, "path": "p", "comments": {"nodes": []}})
        self.state["auto_merge"] = {"mergeMethod": "MERGE", "enabledBy": {"login": "qvictl"}}
        self.run_gate()
        self.assertIsNone(self.automerge())

    def test_coderabbit_approval_is_dismissed_while_conditions_fail(self):
        # App approvals count toward the required approval (seen on qvictl/koreader#14).
        self.state["reviews"] = [review("coderabbitai[bot]", "APPROVED", rid=20),
                                 review("qvictl", "APPROVED", rid=21)]
        self.state["threads"].append({"isResolved": False, "path": "p", "comments": {"nodes": []}})
        self.run_gate()
        self.assertEqual(self.dismissed(), ["repos/%s/pulls/7/reviews/20/dismissals" % REPO])  # not the human's

    def test_coderabbit_approval_is_kept_while_checks_are_pending(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "APPROVED", rid=20)]
        self.state["check_runs"][0].update(status="in_progress", conclusion=None)
        self.run_gate()
        self.assertEqual(self.dismissed(), [])

    def test_coderabbit_approval_is_dismissed_when_a_check_fails(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "APPROVED", rid=20)]
        self.state["check_runs"][0]["conclusion"] = "failure"
        self.run_gate()
        self.assertEqual(self.dismissed(), ["repos/%s/pulls/7/reviews/20/dismissals" % REPO])

    def test_coderabbit_approval_is_kept_when_conditions_hold(self):
        self.state["reviews"] = [review("coderabbitai[bot]", "APPROVED", rid=20)]
        self.run_gate()
        self.assertEqual(self.dismissed(), [])

    def test_foreign_bot_approval_without_marker_is_dismissed(self):
        self.state["reviews"].append(review("github-actions[bot]", "APPROVED", rid=9, body="LGTM"))
        self.run_gate()
        self.assertEqual(len(self.dismissed()), 1)
        self.assertTrue(self.approved())

    def test_dismiss_failure_is_reported_not_raised(self):
        self.state["reviews"].append(review("github-actions[bot]", "APPROVED", commit=OLD, rid=9,
                                            body=rg.APPROVAL_MARKER))
        self.state["reviews"].append(review("coderabbitai[bot]", "CHANGES_REQUESTED", rid=10, at="3"))
        gh = FakeGitHub(self.state)
        gh.fail["repos/%s/pulls/7/reviews/9/dismissals" % REPO] = 403
        facts = rg.collect(gh, REPO, 7)
        verdict = rg.evaluate(facts, CONFIG)
        actions, _ = rg.apply(gh, gh, facts, verdict, False, log=lambda _m: None)
        self.assertTrue(any("失败" in a for a in actions))
        self.assertIn("HTTP 403", rg.render(facts, verdict, False))

    def test_failed_approval_is_shown_in_the_comment(self):
        gh = FakeGitHub(self.state)
        facts = rg.collect(gh, REPO, 7)
        gh.fail["repos/%s/pulls/7/reviews" % REPO] = 422
        verdict = rg.evaluate(facts, CONFIG)
        rg.apply(gh, None, facts, verdict, False, log=lambda _m: None)
        self.assertIn("批准 `aaaaaaaaaa` 失败（HTTP 422）", rg.render(facts, verdict, False))


class EventTest(unittest.TestCase):
    def setUp(self) -> None:
        self.state = base_state()
        self.gh = FakeGitHub(self.state)

    def test_events(self):
        self.assertIsNone(rg.prs_from_event(self.gh, REPO, "schedule", {}))
        self.assertIsNone(rg.prs_from_event(self.gh, REPO, "workflow_dispatch", {"inputs": {"pr": ""}}))
        self.assertEqual(rg.prs_from_event(self.gh, REPO, "workflow_dispatch", {"inputs": {"pr": "12"}}), [12])
        for name in ("pull_request_target", "pull_request_review", "pull_request_review_comment"):
            self.assertEqual(rg.prs_from_event(self.gh, REPO, name, {"pull_request": {"number": 3}}), [3])
        self.assertEqual(rg.prs_from_event(self.gh, REPO, "workflow_run", {
            "workflow_run": {"head_sha": HEAD, "pull_requests": [{"number": 4}]}}), [4])
        self.state["commit_pulls"] = [{"number": 5, "state": "open"}, {"number": 6, "state": "closed"}]
        self.assertEqual(rg.prs_from_event(self.gh, REPO, "workflow_run", {
            "workflow_run": {"head_sha": HEAD, "pull_requests": []}}), [5])
        self.assertEqual(rg.prs_from_event(self.gh, REPO, "check_suite", {
            "check_suite": {"head_sha": HEAD, "pull_requests": []}}), [5])
        self.assertEqual(rg.prs_from_event(self.gh, REPO, "status", {"sha": HEAD}), [5])

    def test_out_of_scope_pr_is_left_alone(self):
        self.state["pr"]["base"]["ref"] = "pr/upstream-feature"
        with self.assertRaises(rg.OutOfScope):
            rg.collect(self.gh, REPO, 7)
        self.state["pr"]["base"]["ref"] = "main"
        self.state["pr"]["state"] = "closed"
        out = rg.process(self.gh, None, REPO, 7, CONFIG, False, self.state["repo"], {})  # noqa
        self.assertIsNone(out)
        self.assertEqual(self.gh.writes, [])


class ScheduleTest(GateCase):
    NOW = rg.datetime(2026, 10, 28, 11, 37, tzinfo=rg.timezone.utc)  # not a refresh slot

    def sticky(self, blockers: str, head: str = HEAD, updated: str = "2026-10-28T11:00:00Z") -> Dict[str, Any]:
        return {"id": 5, "user": {"login": "github-actions[bot]"}, "updated_at": updated,
                "body": "%s\n<!-- review-gate:state head=%s blockers=%s -->\n..." % (rg.MARKER, head, blockers)}

    def needs(self, sticky):
        return rg.schedule_needs_eval(self.state["pr"], sticky, self.NOW)[0]

    def test_state_marker_in_comment(self):
        self.state["reviews"] = []
        self.state["threads"].append({"isResolved": False, "path": "p", "comments": {"nodes": []}})
        self.run_gate()
        self.assertIn("<!-- review-gate:state head=%s blockers=ai,threads -->" % HEAD, self.body)
        self.assertEqual(rg.STATE_RE.search(self.body).group(2), "ai,threads")

    def test_skip_rules(self):
        self.assertTrue(self.needs(None))
        self.assertTrue(self.needs({"user": {"login": "github-actions[bot]"}, "body": rg.MARKER}))
        self.assertTrue(self.needs(self.sticky("ai", head=OLD)))
        self.assertTrue(self.needs(self.sticky("threads")))
        self.assertTrue(self.needs(self.sticky("")))
        self.assertTrue(self.needs(self.sticky("ai,threads")))
        self.assertTrue(self.needs(self.sticky("ai")))
        self.assertFalse(self.needs(self.sticky("checks,ai")))
        self.assertFalse(self.needs(self.sticky("sensitive,author")))
        slot = rg.datetime(2026, 10, 28, 12, 7, tzinfo=rg.timezone.utc)
        self.assertTrue(rg.schedule_needs_eval(self.state["pr"], self.sticky("size"), slot)[0])
        late = rg.datetime(2026, 10, 28, 12, 22, tzinfo=rg.timezone.utc)
        self.assertFalse(rg.schedule_needs_eval(self.state["pr"], self.sticky("size"), late)[0])

    def test_schedule_run_only_evaluates_changed_prs(self):
        self.run_gate()  # produce a real body: OK state
        fake = FakeGitHub(self.state)
        self.state["comments"] = [self.sticky("ai,sensitive", updated=rg.datetime.now(rg.timezone.utc)
                                              .strftime("%Y-%m-%dT%H:%M:%SZ"))]
        with tempfile.TemporaryDirectory() as tmp:
            event = Path(tmp) / "event.json"
            event.write_text(json.dumps({"schedule": "7,22,37,52 * * * *"}))
            old_env, old_cls = dict(os.environ), rg.GitHub
            os.environ.update({"GITHUB_TOKEN": "t", "GITHUB_EVENT_PATH": str(event), "GITHUB_EVENT_NAME": "schedule"})
            rg.GitHub = lambda *_a, **_k: fake  # type: ignore
            old_now = rg.utcnow
            rg.utcnow = lambda: self.NOW  # type: ignore  # outside the refresh slots
            try:
                rg.main(["--repo", REPO, "--event", "--summary", str(Path(tmp) / "s.md")])
                self.assertEqual(fake.writes, [])  # skipped: no evaluation, no write
                self.state["comments"] = [self.sticky("ai", head=OLD)]
                rg.main(["--repo", REPO, "--event", "--summary", str(Path(tmp) / "s.md")])
                self.assertTrue(any(w[0] == "PATCH" for w in fake.writes))  # head moved: evaluated
            finally:
                rg.utcnow = old_now  # type: ignore
                rg.GitHub = old_cls  # type: ignore
                os.environ.clear()
                os.environ.update(old_env)


class MainTest(unittest.TestCase):
    def test_main_event_mode_end_to_end(self):
        state = base_state()
        fake = FakeGitHub(state)
        with tempfile.TemporaryDirectory() as tmp:
            event = Path(tmp) / "event.json"
            event.write_text(json.dumps({"pull_request": {"number": 7}}))
            summary = Path(tmp) / "summary.md"
            env = {"GITHUB_TOKEN": "t", "GITHUB_EVENT_PATH": str(event), "GITHUB_EVENT_NAME": "pull_request_target",
                   "REVIEW_GATE_DRY_RUN": "true"}
            old_env, old_cls = dict(os.environ), rg.GitHub
            os.environ.update(env)
            rg.GitHub = lambda *_a, **_k: fake  # type: ignore
            try:
                code = rg.main(["--repo", REPO, "--event", "--summary", str(summary)])
            finally:
                rg.GitHub = old_cls  # type: ignore
                os.environ.clear()
                os.environ.update(old_env)
            self.assertEqual(code, 0)
            self.assertEqual(fake.writes, [])
            self.assertIn("## #7", summary.read_text())

    def test_repo_config_files_are_valid(self):
        here = Path(__file__).resolve().parent
        config = rg.load_config(str(here / "config.json"))
        self.assertIn("merge_method", config)
        self.assertIn(config["merge_method"], ("MERGE", "SQUASH", "REBASE"))
        for key in ("max_changed_lines", "sensitive_paths", "test_paths"):
            self.assertNotIn(key, config)


if __name__ == "__main__":
    unittest.main()
