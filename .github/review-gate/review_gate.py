#!/usr/bin/env python3
"""Review gate: approve and auto-merge a pull request only when it is safe.

Fork-owned tool shared by qvictl/koreader, qvictl/koreader-base and
qvictl/weread.koplugin (identical file in each; per-repository settings live
in `config.json` next to it). See REVIEW_POLICY.md for the policy.

The gate approves (as github-actions[bot]) and enables auto-merge only when
ALL conditions hold on the PR's head commit:

  1. every required status check of the base branch succeeded;
  2. at least one AI reviewer (CodeRabbit / Gemini Code Assist) reviewed the
     head commit and no AI reviewer's latest decisive review requests changes;
  3. no unresolved review thread;
  4. at most `max_changed_lines` changed lines outside tests and docs;
  5. no sensitive path touched (CI, policy, release, updater, credentials...);
  6. not a draft, no `do-not-merge` label, author is a collaborator or has
     a merged PR already.

The `human-approved` label waives 4, 5 and the first-time-contributor part of
6, but only when the latest `labeled` event was made by a user with admin or
maintain permission. It never waives 1-3.

It keeps one sticky PR comment (Chinese) up to date, dismisses its own
approval when a new commit arrives or a condition stops holding, and only
disables an auto-merge it enabled itself.

Usage:
  review_gate.py --repo OWNER/REPO --pr N         evaluate one PR
  review_gate.py --repo OWNER/REPO --all-open     evaluate every open PR
  review_gate.py --repo OWNER/REPO --event        PRs of $GITHUB_EVENT_PATH
  options: --dry-run (report only), --config FILE, --summary FILE

Environment: GITHUB_TOKEN (approve, dismiss, comment), REVIEW_GATE_MERGE_TOKEN
(optional, enables auto-merge: merges made with GITHUB_TOKEN would not
trigger the push workflows on the base branch), GITHUB_API_URL.

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

MARKER = "<!-- review-gate -->"
APPROVAL_MARKER = "<!-- review-gate:approve -->"
AUTOMERGE_STATE = "<!-- review-gate:automerge=on -->"
# The commit a maintainer's `human-approved` was applied to (head SHA in the
# `labeled` event's payload), recorded in a separate gate comment.
OVERRIDE_RE = re.compile(r"<!-- review-gate:override head=([0-9a-f]{40}) -->")
# The whole body of an override record (and nothing else) must match.
OVERRIDE_RECORD_RE = re.compile(r"\A审查网关：`human-approved` 由 @[A-Za-z0-9-]+(?:\[bot\])? 添加于提交 `[0-9a-f]{10}`，"
                                r"[^\n<]*\n<!-- review-gate:override head=([0-9a-f]{40}) -->\Z")
STATE_RE = re.compile(r"<!-- review-gate:state head=([0-9a-f]+) blockers=([a-z,]*) -->")
# Scheduled runs re-evaluate a PR only when it may have changed without an
# event (see schedule_needs_eval); every PR is still refreshed this often.
SCHEDULE_REFRESH_HOURS = 6  # full refresh in the first quarter hour of 00, 06, 12, 18 UTC
GATE_LOGIN = "github-actions[bot]"
AI_REVIEWERS = {
    "coderabbitai[bot]": "CodeRabbit",
    "gemini-code-assist[bot]": "Gemini Code Assist",
}
# CodeRabbit also reports every review as a check run on the reviewed commit
# ("CodeRabbit", summary "Result: Success - Review completed"). When a review
# produces no actionable comment it posts no PR review at all, so this check
# run is the evidence that the head commit was reviewed.
AI_CHECK_RUNS = {"coderabbitai": ("CodeRabbit", "CodeRabbit")}  # app slug: (check name, reviewer)
AI_CHECK_DONE = re.compile(r"Review completed", re.IGNORECASE)
AI_CHECK_NOT_DONE = re.compile(r"skip|pause|fail|error|cancel", re.IGNORECASE)
OVERRIDE_LABEL = "human-approved"
BLOCK_LABEL = "do-not-merge"
MAINTAINER_ROLES = {"admin", "maintain"}
COLLABORATOR_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
CHECK_OK = {"success", "neutral", "skipped"}
FILES_API_LIMIT = 3000

DEFAULT_CONFIG: Dict[str, Any] = {
    "merge_method": "MERGE",
    "merge_method_overrides": [],
    "max_changed_lines": 500,
    "test_paths": ["spec/**", "**/spec/**", "**/*_spec.lua", "**/test_*.py"],
    "doc_paths": ["**/*.md", "doc/**", "docs/**"],
    "sensitive_paths": [".github/**"],
    "sensitive_line_patterns": [],
    "sync_head_prefix": "sync/upstream-",
}


# --------------------------------------------------------------------------
# Glob matching (`**` crosses directories, `*` and `?` do not, `{a,b}`
# alternatives, not nested).

def glob_to_regex(pattern: str) -> "re.Pattern[str]":
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        elif pattern[i] == "{" and "}" in pattern[i:]:
            end = pattern.index("}", i)
            out.append("(?:" + "|".join(glob_to_regex(alt).pattern[1:-1] for alt in pattern[i + 1:end].split(",")) + ")")
            i = end + 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def match_any(path: str, patterns: Iterable[str]) -> Optional[str]:
    for pattern in patterns:
        if glob_to_regex(pattern).match(path):
            return pattern
    return None


# --------------------------------------------------------------------------
# GitHub API client (REST + GraphQL), injectable for tests.

class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__("HTTP %s: %s" % (status, message))
        self.status = status


class OutOfScope(Exception):
    """Closed PR, or a PR to another branch than the default one: left alone."""


class GitHub:
    def __init__(self, token: str, api_url: str = "https://api.github.com"):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _request(self, method: str, url: str, body: Any = None) -> Tuple[Any, Dict[str, str]]:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "review-gate")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                headers = {k.lower(): v for k, v in resp.headers.items()}
        except urllib.error.HTTPError as err:
            raise ApiError(err.code, err.read().decode(errors="replace")[:500]) from None
        except (urllib.error.URLError, OSError) as err:  # timeouts, resets, DNS
            raise ApiError(0, "network error: %s" % err) from None
        try:
            return (json.loads(raw) if raw else None), headers
        except ValueError as err:
            raise ApiError(0, "invalid JSON: %s" % err) from None

    def request(self, method: str, path: str, body: Any = None) -> Any:
        url = path if path.startswith("http") else self.api_url + "/" + path.lstrip("/")
        return self._request(method, url, body)[0]

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def get_all(self, path: str, key: Optional[str] = None, limit: int = 3000) -> List[Any]:
        sep = "&" if "?" in path else "?"
        url = self.api_url + "/" + path.lstrip("/") + sep + "per_page=100"
        items: List[Any] = []
        while url and len(items) < limit:
            data, headers = self._request("GET", url)
            items.extend(data[key] if key else data)
            url = None
            for part in headers.get("link", "").split(","):
                if 'rel="next"' in part:
                    url = part[part.index("<") + 1:part.index(">")]
        return items

    def graphql(self, query: str, variables: Dict[str, Any]) -> Any:
        data = self.request("POST", "graphql", {"query": query, "variables": variables})
        if data.get("errors"):
            raise ApiError(200, json.dumps(data["errors"])[:500])
        return data["data"]


THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      autoMergeRequest { mergeMethod enabledBy { login } }
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          path
          comments(first: 1) { nodes { author { login } url } }
        }
      }
    }
  }
}
"""


# --------------------------------------------------------------------------
# Facts: everything the decision needs, collected from the API.

@dataclass
class Facts:
    repo: str
    pr: Dict[str, Any]
    owner_login: str
    default_branch: str
    allow_auto_merge: bool
    required_checks: List[Dict[str, Any]]
    required_checks_error: Optional[str]
    check_runs: List[Dict[str, Any]]
    statuses: List[Dict[str, Any]]
    reviews: List[Dict[str, Any]]
    threads: List[Dict[str, Any]]
    files: List[Dict[str, Any]]
    ai_activity: bool
    override_actor: Optional[str] = None
    override_role: Optional[str] = None
    override_error: Optional[str] = None
    override_head: Optional[str] = None
    author_merged_prs: Optional[int] = None
    auto_merge: Optional[Dict[str, Any]] = None
    pr_node_id: Optional[str] = None
    sticky: Optional[Dict[str, Any]] = None

    @property
    def head_sha(self) -> str:
        return self.pr["head"]["sha"]

    @property
    def labels(self) -> List[str]:
        return [label["name"] for label in self.pr.get("labels", [])]

    @property
    def author(self) -> str:
        return (self.pr.get("user") or {}).get("login", "")


def collect(gh: GitHub, repo: str, number: int, repo_info: Optional[Dict[str, Any]] = None,
            branch_cache: Optional[Dict[str, Any]] = None, label_head: Optional[str] = None) -> Facts:
    """`label_head`: head SHA from the payload of the `labeled` event that added
    `human-approved` (only set for that event's own run)."""
    owner, name = repo.split("/", 1)
    repo_info = repo_info or gh.get("repos/%s" % repo)
    pr = gh.get("repos/%s/pulls/%d" % (repo, number))
    if not in_scope(pr, repo_info["default_branch"]):
        raise OutOfScope(number)
    head = pr["head"]["sha"]
    base = pr["base"]["ref"]

    required: List[Dict[str, Any]] = []
    required_error = None
    try:
        cache = branch_cache if branch_cache is not None else {}
        if base not in cache:
            cache[base] = gh.get("repos/%s/branches/%s" % (repo, urllib.parse.quote(base, safe="")))
        protection = (cache[base].get("protection") or {}).get("required_status_checks") or {}
        checks = protection.get("checks")
        if checks:
            required = [{"context": c["context"], "app_id": c.get("app_id")} for c in checks]
        else:
            required = [{"context": c, "app_id": None} for c in protection.get("contexts", [])]
    except ApiError as err:
        required_error = str(err)

    check_runs = gh.get_all("repos/%s/commits/%s/check-runs" % (repo, head), key="check_runs")
    statuses = gh.get_all("repos/%s/commits/%s/statuses" % (repo, head))
    reviews = gh.get_all("repos/%s/pulls/%d/reviews" % (repo, number))
    files = gh.get_all("repos/%s/pulls/%d/files" % (repo, number), limit=FILES_API_LIMIT)
    comments = gh.get_all("repos/%s/issues/%d/comments" % (repo, number))

    threads: List[Dict[str, Any]] = []
    cursor = None
    auto_merge = None
    node_id = pr.get("node_id")
    while True:
        data = gh.graphql(THREADS_QUERY, {"owner": owner, "name": name, "number": number, "cursor": cursor})
        node = data["repository"]["pullRequest"]
        auto_merge = node.get("autoMergeRequest")
        node_id = node.get("id") or node_id
        threads.extend(node["reviewThreads"]["nodes"])
        page = node["reviewThreads"]["pageInfo"]
        if not page["hasNextPage"]:
            break
        cursor = page["endCursor"]

    ai_logins = set(AI_REVIEWERS)
    ai_activity = any((r.get("user") or {}).get("login") in ai_logins for r in reviews) or any(
        (c.get("user") or {}).get("login") in ai_logins for c in comments) or bool(ai_check_runs(check_runs))
    sticky = find_sticky(comments)

    facts = Facts(
        repo=repo, pr=pr, owner_login=repo_info["owner"]["login"],
        default_branch=repo_info["default_branch"], allow_auto_merge=bool(repo_info.get("allow_auto_merge")),
        required_checks=required, required_checks_error=required_error, check_runs=check_runs,
        statuses=statuses, reviews=reviews, threads=threads, files=files, ai_activity=ai_activity,
        auto_merge=auto_merge, pr_node_id=node_id, sticky=sticky)

    if OVERRIDE_LABEL in facts.labels:
        facts.override_actor, facts.override_role, facts.override_error = labeler_role(
            gh, repo, number, facts.owner_login)
        facts.override_head = label_head or bound_override_head(comments)
        if not facts.override_error and facts.override_head != head:
            facts.override_error = (
                "它是在提交 `%s` 上添加的，当前 head 是 `%s`：管理员看过新改动后需移除并重新添加"
                % (facts.override_head[:10], head[:10]) if facts.override_head else
                "网关没有记录到它添加时的提交（例如那次运行被取消）：请移除并重新添加")

    if pr.get("author_association") not in COLLABORATOR_ASSOCIATIONS and facts.author:
        query = urllib.parse.quote("repo:%s is:pr is:merged author:%s" % (repo, facts.author))
        try:
            facts.author_merged_prs = int(gh.get("search/issues?q=%s&per_page=1" % query)["total_count"])
        except ApiError:
            facts.author_merged_prs = None
    return facts


def bound_override_head(comments: List[Dict[str, Any]]) -> Optional[str]:
    """Head SHA from the gate's latest override record. Records are separate
    comments that only the run of a `labeled` event creates and nothing
    edits, so concurrent runs updating the sticky comment cannot lose them."""
    head = None
    for c in comments:
        if (c.get("user") or {}).get("login") == GATE_LOGIN:
            m = OVERRIDE_RECORD_RE.match(c.get("body", ""))
            if m:
                head = m.group(1)
    return head


def labeler_role(gh: GitHub, repo: str, number: int, owner_login: str) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """Who applied the override label last, and their permission (fail closed)."""
    try:
        events = gh.get_all("repos/%s/issues/%d/events" % (repo, number))
    except ApiError as err:
        return None, None, "无法读取标签事件：%s" % err
    actor = None
    for event in events:
        if event.get("event") == "labeled" and (event.get("label") or {}).get("name") == OVERRIDE_LABEL:
            actor = (event.get("actor") or {}).get("login")
    if not actor:
        return None, None, "找不到 `%s` 的打标签事件" % OVERRIDE_LABEL
    if actor == owner_login:
        return actor, "admin", None
    try:
        perm = gh.get("repos/%s/collaborators/%s/permission" % (repo, urllib.parse.quote(actor)))
    except ApiError as err:
        return actor, None, "无法确认 @%s 的权限：%s" % (actor, err)
    return actor, perm.get("role_name") or perm.get("permission"), None


# --------------------------------------------------------------------------
# Decision (pure).

@dataclass
class Condition:
    key: str
    title: str
    ok: bool
    detail: str
    waived: bool = False
    pending: bool = False


@dataclass
class Verdict:
    conditions: List[Condition]
    override: bool
    override_note: str
    approvable: bool
    approvable_note: str
    is_sync: bool
    merge_method: str
    notes: List[str] = field(default_factory=list)
    defer_automerge: bool = False

    @property
    def ok(self) -> bool:
        return all(c.ok or c.waived for c in self.conditions) and self.approvable

    @property
    def blockers(self) -> List[Condition]:
        return [c for c in self.conditions if not (c.ok or c.waived)]


def newest(runs: List[Dict[str, Any]]) -> Dict[str, Any]:
    """The most recent check run. A run that is not completed and has not
    started yet (queued, `started_at` null) is newer than any started one: it
    was created by a later push or re-run, so an older success must not count
    while it is pending. A completed run without `started_at` is not treated
    as newest (the Checks API does not require the field)."""
    return max(runs, key=lambda r: (r.get("started_at") is None and r.get("status") != "completed",
                                    r.get("started_at") or "", r.get("id") or 0))


def latest_by_name(runs: List[Dict[str, Any]], context: str, app_id: Optional[int]) -> Optional[Dict[str, Any]]:
    matching = [r for r in runs if r.get("name") == context
                and (app_id in (None, -1) or (r.get("app") or {}).get("id") == app_id)]
    return newest(matching) if matching else None


def check_required(facts: Facts) -> Condition:
    title = "必需检查全部通过"
    if facts.required_checks_error:
        return Condition("checks", title, False, "无法读取 `%s` 的分支保护：%s" % (
            facts.pr["base"]["ref"], facts.required_checks_error))
    if not facts.required_checks:
        return Condition("checks", title, False, "`%s` 没有配置必需检查，网关不会自动批准" % facts.pr["base"]["ref"])
    failed, pending = [], []
    for req in facts.required_checks:
        context = req["context"]
        run = latest_by_name(facts.check_runs, context, req.get("app_id"))
        if run is not None:
            if run.get("status") != "completed":
                pending.append("`%s`（%s）" % (context, run.get("status")))
            elif run.get("conclusion") not in CHECK_OK:
                failed.append("`%s`（%s）" % (context, run.get("conclusion")))
            continue
        statuses = [s for s in facts.statuses if s.get("context") == context]
        if statuses:
            state = max(statuses, key=lambda s: (s.get("updated_at") or "", s.get("id") or 0)).get("state")
            if state == "pending":
                pending.append("`%s`（pending）" % context)
            elif state != "success":
                failed.append("`%s`（%s）" % (context, state))
            continue
        pending.append("`%s`（尚未上报）" % context)
    if failed:
        return Condition("checks", title, False, "失败：" + "、".join(failed)
                         + ("；等待：" + "、".join(pending) if pending else ""))
    if pending:
        return Condition("checks", title, False, "等待：" + "、".join(pending), pending=True)
    return Condition("checks", title, True, "%d 项必需检查均已通过（%s）" % (
        len(facts.required_checks), "、".join("`%s`" % r["context"] for r in facts.required_checks)))


def ai_check_runs(runs: List[Dict[str, Any]]) -> List[Tuple[str, Dict[str, Any]]]:
    """(reviewer, latest run) for every AI reviewer that reports a check run."""
    found = []
    for slug, (name, label) in AI_CHECK_RUNS.items():
        mine = [r for r in runs if (r.get("app") or {}).get("slug") == slug and r.get("name") == name]
        if mine:
            found.append((label, newest(mine)))
    return found


def check_ai(facts: Facts) -> Condition:
    title = "AI 审查已覆盖最新提交且无 Request changes"
    head = facts.head_sha
    reviewed_head, requesting, seen, running = [], [], set(), []
    for label, run in ai_check_runs(facts.check_runs):
        seen.add(label)
        output = run.get("output") or {}
        text = "%s %s" % (output.get("title") or "", output.get("summary") or "")
        if run.get("status") != "completed":
            running.append(label)
        elif (run.get("conclusion") == "success" and AI_CHECK_DONE.search(text)
              and not AI_CHECK_NOT_DONE.search(output.get("title") or "")):
            reviewed_head.append(label)
    for login, label in AI_REVIEWERS.items():
        mine = [r for r in facts.reviews if (r.get("user") or {}).get("login") == login
                and r.get("state") not in ("PENDING",)]
        if not mine:
            continue
        seen.add(label)
        if any(r.get("commit_id") == head and r.get("state") != "DISMISSED" for r in mine) and label not in reviewed_head:
            reviewed_head.append(label)
        decisive = [r for r in mine if r.get("state") in ("APPROVED", "CHANGES_REQUESTED")]
        if decisive:
            last = max(decisive, key=lambda r: (r.get("submitted_at") or "", r.get("id") or 0))
            if last["state"] == "CHANGES_REQUESTED":
                requesting.append(label)
    if requesting:
        return Condition("ai", title, False, "%s 的最新审查结论是 **Request changes**：修复或逐条回复后，让其重新审查"
                         % "、".join(requesting))
    if reviewed_head:
        return Condition("ai", title, True, "%s 已审查 `%s`" % ("、".join(reviewed_head), head[:10]))
    if running:
        return Condition("ai", title, False, "%s 正在审查 `%s`" % ("、".join(running), head[:10]), pending=True)
    if not facts.ai_activity:
        return Condition("ai", title, False, "等待 AI 审查：本 PR 尚无 CodeRabbit / Gemini Code Assist 的审查"
                         "（应用可能尚未安装——咨询模式，网关只报告、不批准）", pending=True)
    return Condition("ai", title, False, "等待 AI 审查最新提交 `%s`（已审查过旧提交的：%s；可评论 `@coderabbitai review` 或 "
                     "`/gemini review` 请求重新审查）" % (head[:10], "、".join(sorted(seen)) or "无"), pending=True)


def check_threads(facts: Facts) -> Condition:
    title = "没有未解决的审查对话"
    open_threads = [t for t in facts.threads if not t.get("isResolved")]
    if not open_threads:
        return Condition("threads", title, True, "%d 个对话均已解决" % len(facts.threads) if facts.threads
                         else "没有审查对话")
    links = []
    for thread in open_threads[:5]:
        first = (thread.get("comments") or {}).get("nodes") or [{}]
        author = ((first[0].get("author") or {}).get("login")) or "?"
        links.append("[%s](%s) @%s" % (thread.get("path") or "PR", first[0].get("url", ""), author))
    more = "；另有 %d 个" % (len(open_threads) - 5) if len(open_threads) > 5 else ""
    return Condition("threads", title, False, "%d 个未解决：%s%s。AI 指出的潜在问题/bug 必须修复，或回复理由后再解决对话"
                     % (len(open_threads), "；".join(links), more))


def changed_lines(facts: Facts, config: Dict[str, Any]) -> Tuple[Optional[int], List[str]]:
    if facts.pr.get("changed_files", 0) > len(facts.files):
        return None, []
    total, counted = 0, []
    excluded = list(config["test_paths"]) + list(config["doc_paths"])
    for f in facts.files:
        if match_any(f["filename"], excluded):
            continue
        n = int(f.get("additions", 0)) + int(f.get("deletions", 0))
        total += n
        if n:
            counted.append(f["filename"])
    return total, counted


def check_size(facts: Facts, config: Dict[str, Any]) -> Condition:
    limit = int(config["max_changed_lines"])
    title = "非测试、非文档改动 ≤ %d 行" % limit
    total, counted = changed_lines(facts, config)
    if total is None:
        return Condition("size", title, False, "改动文件数 %d 超过 API 上限，无法统计" % facts.pr.get("changed_files", 0))
    if total <= limit:
        return Condition("size", title, True, "%d 行（%d 个文件）" % (total, len(counted)))
    return Condition("size", title, False, "%d 行，超过 %d 行（需拆分 PR，或由管理员加 `%s`）" % (total, limit, OVERRIDE_LABEL))


def changed_patch_lines(patch: str) -> List[str]:
    return [line[1:] for line in patch.splitlines()
            if line[:1] in "+-" and not line.startswith(("+++", "---"))]


def sensitive_hits(facts: Facts, config: Dict[str, Any]) -> List[str]:
    hits = []
    for f in facts.files:
        names = [f["filename"]] + ([f["previous_filename"]] if f.get("previous_filename") else [])
        hit = None
        for path in names:
            pattern = match_any(path, config["sensitive_paths"])
            if pattern:
                hit = "`%s`（%s）" % (path, pattern)
                break
            for rule in config["sensitive_line_patterns"]:
                if not glob_to_regex(rule["path"]).match(path):
                    continue
                patch = f.get("patch")
                if patch is None:
                    hit = "`%s`（%s；无法读取 diff）" % (path, rule["description"])
                    break
                regex = re.compile(rule["regex"])
                if any(regex.search(line) for line in changed_patch_lines(patch)):
                    hit = "`%s`（%s）" % (path, rule["description"])
                    break
            if hit:
                break
        if hit:
            hits.append(hit)
    return hits


def check_sensitive(facts: Facts, config: Dict[str, Any]) -> Condition:
    title = "未触及敏感路径"
    if facts.pr.get("changed_files", 0) > len(facts.files):
        return Condition("sensitive", title, False, "改动文件过多，无法逐一检查")
    hits = sensitive_hits(facts, config)
    if not hits:
        return Condition("sensitive", title, True, "未触及 CI、策略、发布、更新器或凭据相关文件")
    shown = "、".join(hits[:8]) + ("等 %d 个" % len(hits) if len(hits) > 8 else "")
    return Condition("sensitive", title, False, "触及：%s。这些改动必须由人审核（管理员确认后加 `%s`）"
                     % (shown, OVERRIDE_LABEL))


def check_eligibility(facts: Facts, override: bool) -> Tuple[Condition, Optional[str]]:
    """Condition 6. Returns (condition, waivable part that failed)."""
    title = "非草稿、无 `%s`、作者可信" % BLOCK_LABEL
    pr = facts.pr
    problems, first_timer = [], None
    if pr.get("draft"):
        problems.append("PR 仍是草稿")
    if BLOCK_LABEL in facts.labels:
        problems.append("有 `%s` 标签" % BLOCK_LABEL)
    assoc = pr.get("author_association", "NONE")
    if facts.author == GATE_LOGIN:
        return Condition("eligible", title, False, "；".join(
            problems + ["作者是 github-actions[bot]（自动化 PR），网关不能批准，见下方说明"])), None
    if assoc in COLLABORATOR_ASSOCIATIONS:
        who = "作者 @%s 是仓库协作者（%s）" % (facts.author, assoc)
    elif facts.author_merged_prs:
        who = "外部作者 @%s 已有 %d 个合并的 PR" % (facts.author, facts.author_merged_prs)
    else:
        first_timer = "外部作者 @%s 尚无合并过的 PR（首次贡献）" % facts.author
        if facts.author_merged_prs is None and assoc not in ("FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "NONE"):
            first_timer += "，或无法查询"
        who = first_timer
    if problems:
        return Condition("eligible", title, False, "；".join(problems + [who])), first_timer
    if first_timer:
        return Condition("eligible", title, False, who + "：需管理员加 `%s`" % OVERRIDE_LABEL,
                         waived=override), first_timer
    return Condition("eligible", title, True, who), None


def merge_method_for(facts: Facts, config: Dict[str, Any]) -> str:
    head_ref = facts.pr["head"]["ref"]
    for rule in config.get("merge_method_overrides", []):
        if glob_to_regex(rule["head_ref"]).match(head_ref):
            return rule["method"]
    return config["merge_method"]


def evaluate(facts: Facts, config: Dict[str, Any]) -> Verdict:
    override, override_note = False, ""
    if OVERRIDE_LABEL in facts.labels:
        if facts.override_error:
            override_note = "`%s` 无效：%s" % (OVERRIDE_LABEL, facts.override_error)
        elif facts.override_role in MAINTAINER_ROLES:
            override = True
            override_note = "`%s` 由 @%s（%s）添加：豁免第 4、5 项和首次贡献者限制（不豁免 1–3）" % (
                OVERRIDE_LABEL, facts.override_actor, facts.override_role)
        else:
            override_note = "`%s` 被忽略：最后添加它的 @%s 权限为 %s，只有 admin / maintain 才有效" % (
                OVERRIDE_LABEL, facts.override_actor, facts.override_role or "未知")

    size = check_size(facts, config)
    sensitive = check_sensitive(facts, config)
    if override:
        size.waived = not size.ok
        sensitive.waived = not sensitive.ok
    eligible, _ = check_eligibility(facts, override)
    conditions = [check_required(facts), check_ai(facts), check_threads(facts), size, sensitive, eligible]

    is_sync = facts.pr["head"]["ref"].startswith(config.get("sync_head_prefix", "sync/upstream-")) or \
        "upstream-sync" in facts.labels
    approvable, approvable_note = True, ""
    if facts.author == GATE_LOGIN:
        approvable = False
        approvable_note = ("本 PR 由 github-actions[bot] 创建（上游同步 PR）。GitHub 不允许 github-actions 批准自己创建的 PR，"
                           "所以网关永远不会批准它：需要仓库所有者审核后手动批准并合并；或配置 `SYNC_TOKEN`，"
                           "让同步 PR 以所有者身份创建（届时仍需满足 1–3 并由管理员加 `%s`）。" % OVERRIDE_LABEL)
    verdict = Verdict(conditions, override, override_note, approvable, approvable_note, is_sync,
                      merge_method_for(facts, config))
    return verdict


# --------------------------------------------------------------------------
# Rendering.

def icon(c: Condition) -> str:
    if c.ok:
        return "✅"
    if c.waived:
        return "☑️"
    return "⏳" if c.pending else "❌"


def render(facts: Facts, verdict: Verdict, automerge_on: bool) -> str:
    """The sticky comment. Deterministic for a given state (no timestamps, no
    per-run actions) so that unchanged PRs are not edited every run."""
    head = facts.head_sha
    keys = [c.key for c in verdict.blockers] + ([] if verdict.approvable else ["author"])
    lines = [MARKER, "<!-- review-gate:state head=%s blockers=%s -->" % (head, ",".join(keys))]
    if automerge_on:
        lines.append(AUTOMERGE_STATE)
    if verdict.ok:
        status = "✅ **满足全部条件**：网关批准" + ("并开启自动合并" if automerge_on else "")
    else:
        status = "⛔ **暂不自动批准**（%d 项未满足）" % len(verdict.blockers) if verdict.blockers else \
            "⛔ **暂不自动批准**"
    lines += ["### 🛡️ 审查网关 Review gate", "",
              "%s · 提交 `%s` · 合并方式 `%s`" % (status, head[:10], verdict.merge_method.lower()), "",
              "| # | 条件 | 状态 | 说明 |", "|---|---|---|---|"]
    for i, c in enumerate(verdict.conditions, 1):
        detail = c.detail + ("（已被 `%s` 豁免）" % OVERRIDE_LABEL if c.waived else "")
        detail = detail.replace("|", "\\|").replace("\n", " ").replace("<", "&lt;")  # no HTML from PR data
        lines.append("| %d | %s | %s | %s |" % (i, c.title, icon(c), detail))
    lines.append("")
    if verdict.override_note:
        lines += ["**覆盖：** " + verdict.override_note, ""]
    if not verdict.approvable:
        lines += ["**无法自动批准：** " + verdict.approvable_note, ""]
    if verdict.is_sync and verdict.approvable:
        lines += ["**上游同步 PR：** 改动行数和敏感路径几乎必然超限，需要仓库所有者审核后加 `%s`，并且仍需 AI 审查（可评论 "
                  "`@coderabbitai review`）。合并时必须用 merge commit。" % OVERRIDE_LABEL, ""]
    for note in verdict.notes:
        lines += ["- " + note]
    lines += ["", "<sub>网关只在全部条件满足时以 github-actions 身份批准并开启自动合并；新提交或条件不再满足时撤销自己的批准。"
              "规则见 [REVIEW_POLICY.md](../blob/%s/REVIEW_POLICY.md)。</sub>" % facts.default_branch]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Actions.

ENABLE_AUTOMERGE = """
mutation($id: ID!, $method: PullRequestMergeMethod!, $head: GitObjectID!) {
  enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $head}) {
    clientMutationId
  }
}
"""
DISABLE_AUTOMERGE = """
mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId } }
"""


def apply(gh: GitHub, merge_gh: Optional[GitHub], facts: Facts, verdict: Verdict, dry_run: bool,
          log: Callable[[str], None] = print, defer_automerge: bool = False) -> Tuple[List[str], bool]:
    """Approve / dismiss / auto-merge. Returns (actions taken, auto-merge enabled by the gate).

    Without `merge_gh` and with `defer_automerge`, a PR ready for auto-merge is
    only flagged (verdict.defer_automerge): the workflow's `automerge` job, the
    only one that can read REVIEW_GATE_MERGE_TOKEN (environment `review-gate`,
    default branch only), then re-runs the gate for it with the token."""
    repo, number, head = facts.repo, facts.pr["number"], facts.head_sha
    actions: List[str] = []
    gate_enabled_automerge = bool(facts.sticky and AUTOMERGE_STATE in facts.sticky.get("body", ""))
    automerge_on = gate_enabled_automerge and facts.auto_merge is not None

    approvals = [r for r in facts.reviews if (r.get("user") or {}).get("login") == GATE_LOGIN
                 and r.get("state") == "APPROVED"]
    to_dismiss = []
    for review in approvals:
        if not verdict.ok:
            to_dismiss.append((review, "审查网关：条件不再满足（%s）" % "、".join(c.title for c in verdict.blockers)
                               if verdict.blockers else "审查网关：无法自动批准"))
        elif review.get("commit_id") != head:
            to_dismiss.append((review, "审查网关：有新提交，旧批准作废"))
        elif APPROVAL_MARKER not in (review.get("body") or ""):
            to_dismiss.append((review, "审查网关：这条批准不是网关做出的"))
    has_valid = any(r.get("commit_id") == head and APPROVAL_MARKER in (r.get("body") or "")
                    for r in approvals if r not in [d[0] for d in to_dismiss])

    def run(desc: str, fn: Callable[[], Any]) -> bool:
        if dry_run:
            actions.append("（演练）" + desc)
            return True
        try:
            fn()
            actions.append(desc)
            return True
        except ApiError as err:
            actions.append("%s 失败：%s" % (desc, err))
            verdict.notes.append("⚠️ %s 失败（HTTP %s），下次运行会重试" % (desc, err.status))
            log("::warning::%s failed: %s" % (desc, err))
            return False

    for review, message in to_dismiss:
        run("撤销 github-actions 的批准 #%s" % review["id"], lambda r=review, m=message: gh.request(
            "PUT", "repos/%s/pulls/%d/reviews/%d/dismissals" % (repo, number, r["id"]),
            {"message": m, "event": "DISMISS"}))

    if not verdict.ok:
        if gate_enabled_automerge and facts.auto_merge is not None and facts.pr_node_id:
            if run("关闭网关开启的自动合并", lambda: gh.graphql(DISABLE_AUTOMERGE, {"id": facts.pr_node_id})):
                automerge_on = False
        return actions, automerge_on

    if not has_valid:
        body = APPROVAL_MARKER + "\n审查网关：`%s` 满足 REVIEW_POLICY.md 的全部自动批准条件。" % head[:10]
        run("批准 `%s`" % head[:10], lambda: gh.request(
            "POST", "repos/%s/pulls/%d/reviews" % (repo, number),
            {"commit_id": head, "event": "APPROVE", "body": body}))

    if facts.auto_merge is not None:
        if gate_enabled_automerge:
            automerge_on = True
        else:
            verdict.notes.append("自动合并已由 @%s 开启（%s）" % (
                (facts.auto_merge.get("enabledBy") or {}).get("login", "?"),
                str(facts.auto_merge.get("mergeMethod", "?")).lower()))
    elif not facts.allow_auto_merge:
        verdict.notes.append("仓库未开启 *Allow auto-merge*：已批准，需手动合并（启用步骤见 REVIEW_POLICY.md）")
    elif merge_gh is None:
        if defer_automerge:
            verdict.defer_automerge = True
        else:
            verdict.notes.append("自动合并未启用（需要 `REVIEW_GATE_MERGE_TOKEN`，见 REVIEW_POLICY.md 启用步骤）：已批准，需手动合并")
    elif facts.pr_node_id and dry_run:
        actions.append("（演练）开启自动合并（%s）" % verdict.merge_method.lower())
    elif facts.pr_node_id:
        try:
            merge_gh.graphql(ENABLE_AUTOMERGE, {"id": facts.pr_node_id, "method": verdict.merge_method, "head": head})
            actions.append("开启自动合并（%s）" % verdict.merge_method.lower())
            automerge_on = True
        except ApiError as err:
            # GitHub refuses auto-merge on a PR that is mergeable right now:
            # "clean" (all checks green) or "unstable" (only non-required
            # checks failing).
            if not re.search(r"is in (clean|unstable) status", str(err), re.IGNORECASE):
                actions.append("开启自动合并失败：%s" % err)
                verdict.notes.append("⚠️ 开启自动合并失败（HTTP %s），下次运行会重试" % err.status)
                log("::warning::enable auto-merge failed: %s" % err)
            else:
                # Already mergeable: GitHub refuses auto-merge, merge now,
                # pinned to the evaluated head.
                run("直接合并 `%s`（%s）" % (head[:10], verdict.merge_method.lower()), lambda: merge_gh.request(
                    "PUT", "repos/%s/pulls/%d/merge" % (repo, number),
                    {"sha": head, "merge_method": verdict.merge_method.lower()}))
    return actions, automerge_on


def upsert_comment(gh: GitHub, facts: Facts, body: str, dry_run: bool) -> str:
    if facts.sticky and facts.sticky.get("body", "").strip() == body.strip():
        return "unchanged"
    if dry_run:
        return "dry-run"
    if facts.sticky:
        gh.request("PATCH", "repos/%s/issues/comments/%d" % (facts.repo, facts.sticky["id"]), {"body": body})
        return "updated"
    gh.request("POST", "repos/%s/issues/%d/comments" % (facts.repo, facts.pr["number"]), {"body": body})
    return "created"


# --------------------------------------------------------------------------
# Entry points.

def load_config(path: Optional[str]) -> Dict[str, Any]:
    config = dict(DEFAULT_CONFIG)
    path = path or str(Path(__file__).with_name("config.json"))
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            config.update(json.load(fh))
    return config


def in_scope(pr: Dict[str, Any], default_branch: str) -> bool:
    return pr.get("state") == "open" and pr["base"]["ref"] == default_branch


def prs_from_event(gh: GitHub, repo: str, event_name: str, event: Dict[str, Any]) -> Optional[List[int]]:
    """PR numbers for an event; None means every open PR."""
    if event_name in ("schedule",):
        return None
    if event_name == "workflow_dispatch":
        pr = ((event.get("inputs") or {}).get("pr") or "").strip()
        return [int(pr)] if pr else None
    if "pull_request" in event:
        return [int(event["pull_request"]["number"])]
    sha, listed = None, []
    for key in ("workflow_run", "check_suite"):
        if key in event:
            listed = [int(p["number"]) for p in event[key].get("pull_requests") or []]
            sha = event[key].get("head_sha")
    if event_name == "status":
        sha = event.get("sha")
    if listed:
        return listed
    if sha:
        return [int(p["number"]) for p in gh.get("repos/%s/commits/%s/pulls" % (repo, sha)) if p.get("state") == "open"]
    return []


def schedule_needs_eval(pr: Dict[str, Any], sticky: Optional[Dict[str, Any]], now: datetime) -> Tuple[bool, str]:
    """Light-weight check for scheduled runs (one API call per PR).

    Pushes, labels, reviews, review comments and check completion all trigger
    the gate directly; the schedule is the safety net for what has no trigger
    (a review thread resolved or unresolved) and for missed events. So a PR is
    re-evaluated only when it has no sticky comment yet, its head moved, it is
    blocked by unresolved threads only, it was approved (conditions may stop
    holding), or it is a refresh slot (every SCHEDULE_REFRESH_HOURS hours)."""
    if not sticky:
        return True, "no sticky comment"
    m = STATE_RE.search(sticky.get("body", ""))
    if not m:
        return True, "no state marker"
    head, blockers = m.group(1), set(filter(None, m.group(2).split(",")))
    if head != pr["head"]["sha"]:
        return True, "head moved"
    if blockers <= {"threads", "ai"}:
        # No event fires when a thread is resolved, nor (in general) when
        # CodeRabbit's check suite completes on a SHA that already has one.
        return True, "approved or only blocked by AI review / threads"
    # The comment is not edited when unchanged, so its age cannot drive the
    # refresh: use fixed slots instead (one scheduled run per slot).
    if now.hour % SCHEDULE_REFRESH_HOURS == 0 and now.minute < 15:
        return True, "periodic refresh"
    return False, "unchanged (blocked by %s)" % ",".join(sorted(blockers))


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def find_sticky(comments: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    return next((c for c in comments
                 if (c.get("user") or {}).get("login") == GATE_LOGIN and c.get("body", "").startswith(MARKER)), None)


def process(gh: GitHub, merge_gh: Optional[GitHub], repo: str, number: int, config: Dict[str, Any], dry_run: bool,
            repo_info: Dict[str, Any], branch_cache: Dict[str, Any],
            defer_automerge: bool = False, label_head: Optional[str] = None) -> Optional[Tuple[str, bool]]:
    try:
        facts = collect(gh, repo, number, repo_info, branch_cache, label_head)
    except OutOfScope:
        print("#%d: not an open PR to %s, skipped" % (number, repo_info["default_branch"]))
        return None
    verdict = evaluate(facts, config)
    actions, automerge_on = apply(gh, merge_gh, facts, verdict, dry_run, defer_automerge=defer_automerge)
    body = render(facts, verdict, automerge_on)
    result = upsert_comment(gh, facts, body, dry_run)
    if label_head and facts.override_actor and not dry_run:
        try:
            gh.request("POST", "repos/%s/issues/%d/comments" % (repo, number), {"body": (
                "审查网关：`%s` 由 @%s 添加于提交 `%s`，只对这个提交有效；之后有新提交需重新添加。\n"
                "<!-- review-gate:override head=%s -->"
                % (OVERRIDE_LABEL, facts.override_actor, label_head[:10], label_head))})
        except ApiError as err:
            print("::warning::#%d: override record not written: %s" % (number, err))
    print("#%d %s: %s; comment %s; actions: %s" % (
        number, facts.head_sha[:10], "OK" if verdict.ok else "blocked by " + ",".join(c.key for c in verdict.blockers),
        result, "; ".join(actions) or "none"))
    done = "\n".join("- " + a for a in actions) or "- 无"
    return "## #%d\n\n%s\n**本次操作：**\n%s\n" % (number, body, done), verdict.defer_automerge


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--pr", type=int)
    group.add_argument("--prs", help="comma / space separated PR numbers (the automerge job)")
    group.add_argument("--all-open", action="store_true")
    group.add_argument("--event", action="store_true")
    ap.add_argument("--config")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = ap.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token or not args.repo:
        print("GITHUB_TOKEN and --repo are required", file=sys.stderr)
        return 2
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    gh = GitHub(token, api)
    merge_token = os.environ.get("REVIEW_GATE_MERGE_TOKEN")
    merge_gh = GitHub(merge_token, api) if merge_token else None
    dry_run = args.dry_run or os.environ.get("REVIEW_GATE_DRY_RUN", "").lower() == "true"
    # Repository variable REVIEW_GATE_AUTOMERGE=on: the token is configured in
    # environment `review-gate`; flag ready PRs for the automerge job.
    defer_automerge = merge_gh is None and os.environ.get("REVIEW_GATE_AUTOMERGE", "").lower() == "on"
    config = load_config(args.config)
    repo_info = gh.get("repos/%s" % args.repo)

    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    label_heads: Dict[int, str] = {}
    numbers: Optional[List[int]]
    if args.pr:
        numbers = [args.pr]
    elif args.prs is not None:
        numbers = [int(n) for n in re.split(r"[,\s]+", args.prs) if n]
    elif args.all_open:
        numbers = None
    else:
        with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
            event = json.load(fh)
        numbers = prs_from_event(gh, args.repo, event_name, event)
        if (event_name == "pull_request_target" and event.get("action") == "labeled"
                and (event.get("label") or {}).get("name") == OVERRIDE_LABEL):
            label_heads[int(event["pull_request"]["number"])] = event["pull_request"]["head"]["sha"]
    if numbers is None:
        open_prs = gh.get_all("repos/%s/pulls?state=open&base=%s" % (
            args.repo, urllib.parse.quote(repo_info["default_branch"], safe="")))
        numbers = []
        now = utcnow()
        for pr in open_prs:
            if args.event and event_name == "schedule":
                try:
                    sticky = find_sticky(gh.get_all("repos/%s/issues/%d/comments" % (args.repo, pr["number"])))
                except ApiError as err:
                    print("::warning::#%d: %s" % (pr["number"], err))
                    continue
                needed, why = schedule_needs_eval(pr, sticky, now)
                if not needed:
                    print("#%d: %s, skipped" % (pr["number"], why))
                    continue
            numbers.append(pr["number"])

    summaries, ready = [], []
    branch_cache: Dict[str, Any] = {}
    for number in sorted(set(numbers)):
        try:
            result = process(gh, merge_gh, args.repo, number, config, dry_run, repo_info, branch_cache,
                             defer_automerge, label_heads.get(number))
            if result:
                summaries.append(result[0])
                if result[1]:
                    ready.append(number)
        except ApiError as err:
            # e.g. the read-only token of a fork PR's review event: the next
            # scheduled run (default branch, write token) catches up.
            print("::warning::review gate failed for #%d: %s" % (number, err))
    if args.summary and summaries:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("\n\n".join(summaries) + "\n")
    if not numbers:
        print("No pull request to evaluate.")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as fh:
            fh.write("automerge=%s\n" % " ".join(str(n) for n in ready))
    return 0


if __name__ == "__main__":
    sys.exit(main())
