#!/usr/bin/env python3
"""Select affected top-level Lua specs from both versions of the dependency graph.

Literal module/path strings deliberately overapproximate imports: this also
accounts for pcall, preload tables, package.loaded fixtures and lazy loaders.
Unclassified dynamic imports fail back to the full suite, never an empty set.
"""
from __future__ import annotations

import argparse
from collections import defaultdict, deque
import json
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[1]
FRAMEWORK = (".github/", ".ci/", ".luacov", "scripts/select_lua_tests.py",
             "scripts/run_lua_", "scripts/coverage_tools.py", "scripts/check_test_policy.py")


def git(*args: str, repo: Path = REPO) -> str:
    return subprocess.check_output(["git", *args], cwd=repo, text=True)


def commit(ref: str, repo: Path) -> str:
    return git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}", repo=repo).strip()


def files_at(sha: str, repo: Path) -> list[str]:
    return sorted(filter(None, git("ls-tree", "-rz", "--name-only", sha, repo=repo).split("\0")))


def sources_at(sha: str, paths: list[str], repo: Path) -> dict[str, str]:
    # A single batch avoids starting git once per Lua file on every CI run.
    if any("\n" in path or "\r" in path for path in paths):
        raise ValueError("unsupported newline in Lua source path")
    data = subprocess.check_output(["git", "cat-file", "--batch"], cwd=repo,
                                   input="".join(f"{sha}:{path}\n" for path in paths).encode())
    result, offset = {}, 0
    for path in paths:
        end = data.index(b"\n", offset)
        _oid, kind, size = data[offset:end].split()
        if kind != b"blob":
            raise ValueError("Lua source is not a Git blob")
        start = end + 1
        offset = start + int(size)
        result[path] = data[start:offset].decode("utf-8", errors="replace")
        offset += 1
    return result


def is_test(path: str) -> bool:
    return path.startswith("spec/") and path.count("/") == 1 and path.endswith("_spec.lua")


def production(path: str) -> bool:
    return path == "main.lua" or path.startswith(("weread/", "integrations/"))


def tokens(source: str) -> list[tuple[str, str]]:
    """Small Lua lexer; comments and long strings cannot become fake imports."""
    result = []
    index = 0
    while index < len(source):
        if source[index].isspace():
            index += 1
            continue
        comment = source.startswith("--", index)
        start = index + 2 if comment else index
        bracket = re.match(r"\[(=*)\[", source[start:])
        if bracket:
            close = "]" + bracket[1] + "]"
            end = source.find(close, start + len(bracket[0]))
            if end < 0:
                raise ValueError("unterminated Lua long string/comment")
            if not comment:
                result.append(("string", source[start + len(bracket[0]):end].lstrip("\n")))
            index = end + len(close)
            continue
        if comment:
            end = source.find("\n", start)
            index = len(source) if end < 0 else end + 1
            continue
        char = source[index]
        if char in "\"'":
            quote, value = char, []
            index += 1
            while index < len(source) and source[index] != quote:
                char = source[index]
                if char == "\\":
                    index += 1
                    if index == len(source):
                        raise ValueError("unterminated Lua escape")
                    escape = source[index]
                    digits = re.match(r"\d{1,3}", source[index:])
                    if digits:
                        value.append(chr(int(digits[0])))
                        index += len(digits[0])
                        continue
                    if escape == "x" and re.match(r"[0-9a-fA-F]{2}", source[index + 1:index + 3]):
                        value.append(chr(int(source[index + 1:index + 3], 16)))
                        index += 3
                        continue
                    if escape == "z":
                        index += 1
                        while index < len(source) and source[index].isspace():
                            index += 1
                        continue
                    value.append({"n": "\n", "r": "\r", "t": "\t"}.get(escape, escape))
                else:
                    value.append(char)
                index += 1
            if index == len(source):
                raise ValueError("unterminated Lua string")
            result.append(("string", "".join(value)))
            index += 1
            continue
        name = re.match(r"[A-Za-z_][A-Za-z_0-9]*", source[index:])
        if name:
            result.append(("name", name[0]))
            index += len(name[0])
        elif source.startswith("..", index):
            result.append(("symbol", ".."))
            index += 2
        else:
            result.append(("symbol", char))
            index += 1
    return result


def literal_array(ts: list[tuple[str, str]], start: int) -> int | None:
    if start >= len(ts) or ts[start][1] != "{":
        return None
    index = start + 1
    while index < len(ts) and ts[index][1] != "}":
        if ts[index][0] != "string":
            return None
        index += 1
        if index < len(ts) and ts[index][1] in (",", ";"):
            index += 1
        elif index >= len(ts) or ts[index][1] != "}":
            return None
    return index if index < len(ts) else None


def bounded_dynamic(path: str, ts: list[tuple[str, str]], call: int, argument: int) -> bool:
    words = [value for _kind, value in ts]
    # Existing menu loop has an inline literal list. Verify the loop and
    # immediate body rather than trusting a path-based blanket exception.
    if path == "weread/ui/menu.lua" and words[call:argument + 1] == ["require", "(", "module"]:
        for index in range(call):
            if words[index:index + 7] != ["for", "_i", ",", "module", "in", "ipairs", "("]:
                continue
            end = literal_array(ts, index + 7)
            if end is not None and words[end + 1:call] == [")", "do", "local", "order", "="]:
                return True
    if path == "weread/lib/runtime.lua" and words[call:argument + 1] == ["require", ",", "name"]:
        declaration = ["Runtime", ".", "PRELOAD_MODULES", "="]
        declared = any(words[index:index + 4] == declaration and literal_array(ts, index + 4) is not None
                       for index in range(len(ts)))
        loop = ["for", "_i", ",", "name", "in", "ipairs", "(", "options", ".", "preload_modules",
                "or", "Runtime", ".", "PRELOAD_MODULES", ")", "do", "local", "ok", ",", "err", "=", "pcall", "("]
        if declared and words[max(0, call - len(loop)):call] == loop:
            return True
    # These optional native-widget fixtures load KOReader frontend files,
    # not plugin modules. A changed root or path shape is unclassified.
    if path in ("spec/empty_state_face_spec.lua", "spec/annotation_chapter_picker_spec.lua"):
        first = words[argument:argument + 3]
        if first[:2] in (["native_widgets", ".."], ["group_root", ".."]):
            return len(first) == 3 and first[2] in ("/frontend/", "/ui/widget/")
    return False


def imports(path: str, source: str, inventory: set[str]) -> tuple[set[str], list[str]]:
    ts = tokens(source)
    edges, unknown = set(), []
    runtime_files = {name for name in inventory if not is_test(name)
                     and not name.startswith(("spec/emulator/", "spec/koreader/"))}
    for index, (kind, value) in enumerate(ts):
        if value == "_G" and index + 1 < len(ts) and ts[index + 1][1] == "[":
            unknown.append(f"unclassified_global_lookup:{path}")
        if value == "package":
            remaining = [item[1] for item in ts[index + 1:index + 7]]
            field_end = None
            if remaining[:2] in ([".", "loaded"], [".", "preload"]):
                field_end = index + 3
            elif remaining[:3] in (["[", "loaded", "]"], ["[", "preload", "]"]):
                field_end = index + 4
            if field_end is not None:
                literal_key = (field_end + 2 < len(ts) and ts[field_end][1] == "["
                               and ts[field_end + 1][0] == "string" and ts[field_end + 2][1] == "]")
                if not literal_key:
                    # Cache fixtures use computed keys or pass the table to
                    # helpers. Every local runtime module is then a possible
                    # dependency of this consumer. Specs run in separate Lua
                    # processes; unrelated suites need not share its cache.
                    edges.update(runtime_files)
        if kind != "string":
            continue
        if value in ("require", "loadfile", "dofile"):
            unknown.append(f"unclassified_loader_name_escape:{path}:{value}")
        path_value = value.removeprefix("./")
        module_path = path_value.replace(".", "/")
        edges.update(inventory.intersection((path_value, module_path + ".lua", module_path + "/init.lua")))
    for index, (kind, value) in enumerate(ts):
        if kind != "name" or value not in ("require", "loadfile", "dofile"):
            continue
        argument = None
        if index + 1 < len(ts) and ts[index + 1][1] == "(":
            argument = index + 2
        elif index + 1 < len(ts) and ts[index + 1][0] == "string":
            continue  # require "module"
        elif index >= 2 and ts[index - 2][1] in ("pcall", "xpcall") and ts[index - 1][1] == "(":
            if index + 1 < len(ts) and ts[index + 1][1] == ",":
                argument = index + 2
        if argument is None:
            unknown.append(f"unclassified_loader_reference:{path}:{value}")
            continue
        literal = argument < len(ts) and ts[argument][0] == "string"
        if literal and argument + 1 < len(ts) and ts[argument + 1][1] in (")", ","):
            continue
        if not bounded_dynamic(path, ts, index, argument):
            unknown.append(f"unclassified_dynamic_import:{path}:{value}")
    # Runtime supports injected preload lists. Literal overrides are already
    # represented by their strings; an expression cannot be silently ignored.
    for index in range(len(ts) - 1):
        if ts[index][1] == "preload_modules" and ts[index + 1][1] == "=":
            if literal_array(ts, index + 2) is None:
                unknown.append(f"unclassified_preload_override:{path}")
    return edges, unknown


def graph(sha: str, repo: Path) -> tuple[dict[str, set[str]], list[str]]:
    inventory = {path for path in files_at(sha, repo) if path.endswith(".lua")}
    result, problems = {}, {}
    try:
        sources = sources_at(sha, sorted(inventory), repo)
    except ValueError as exc:
        return {}, [f"source_graph_unavailable:{exc}"]
    for path, source in sources.items():
        try:
            result[path], problems[path] = imports(path, source, inventory)
        except ValueError as exc:
            result[path], problems[path] = set(), [f"lua_scan_failed:{path}:{exc}"]
    # IT-only dynamic loaders do not affect the Lua unit graph.
    reachable, queue = set(), deque(path for path in inventory if is_test(path))
    while queue:
        path = queue.popleft()
        if path not in reachable:
            reachable.add(path)
            queue.extend(result.get(path, ()))
    return result, sorted({problem for path in reachable for problem in problems.get(path, ())})


def select(base: str | None, head: str, repo: Path = REPO) -> dict:
    head_sha = commit(head, repo)
    all_tests = [path for path in files_at(head_sha, repo) if is_test(path)]
    manifest = dict(schema_version=1, mode="full", base_sha=None, head_sha=head_sha,
                    tests=all_tests, changed_files=[], reasons=[], total_tests=len(all_tests))
    if not base or not base.strip("0"):
        manifest["reasons"] = ["base_unavailable:manual_or_first_push"]
        return manifest
    try:
        base_sha = commit(base, repo)
    except subprocess.CalledProcessError:
        manifest["reasons"] = ["base_unavailable:full_suite"]
        return manifest
    manifest["base_sha"] = base_sha
    changed = sorted(filter(None, git("diff", "--no-renames", "--name-only", "-z", base_sha, head_sha,
                                      repo=repo).split("\0")))
    manifest["changed_files"] = changed
    if any(path.startswith(FRAMEWORK) for path in changed):
        manifest["reasons"] = ["test_framework_or_policy_changed"]
        return manifest
    if not any(production(path) or (path.startswith("spec/") and path.endswith(".lua")
                                   and not path.startswith(("spec/emulator/", "spec/koreader/")))
               for path in changed):
        manifest.update(mode="none", tests=[], reasons=["no_unit_runtime_changes"])
        return manifest
    before, before_unknown = graph(base_sha, repo)
    after, after_unknown = graph(head_sha, repo)
    if before_unknown or after_unknown:
        manifest["reasons"] = sorted(set(before_unknown + after_unknown))
        return manifest
    reverse = defaultdict(set)
    for version in (before, after):
        for source, dependencies in version.items():
            for dependency in dependencies:
                reverse[dependency].add(source)
    def affected_tests(seeds):
        affected, queue = set(seeds), deque(seeds)
        while queue:
            for caller in reverse[queue.popleft()]:
                if caller not in affected:
                    affected.add(caller)
                    queue.append(caller)
        return set(all_tests).intersection(affected)

    chosen = sorted(affected_tests(changed))
    if any(production(path) and not affected_tests([path]) for path in changed):
        manifest["reasons"] = ["production_change_without_matching_test"]
    elif chosen == all_tests:
        manifest["reasons"] = ["all_tests_affected"]
    else:
        manifest.update(mode="selected" if chosen else "none", tests=chosen,
                        reasons=["base_and_head_dependency_closure"])
    return manifest


def validate(manifest: dict, repo: Path = REPO) -> list[str]:
    actual = commit("HEAD", repo)
    tests = [path for path in files_at(actual, repo) if is_test(path)]
    if type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
        raise ValueError("unsupported test selection schema")
    if manifest.get("head_sha") != actual:
        raise ValueError("test selection does not describe the checked-out HEAD")
    chosen = manifest.get("tests")
    if not isinstance(chosen, list) or any(not isinstance(path, str) for path in chosen):
        raise ValueError("invalid selected test list")
    if chosen != sorted(set(chosen)) or not set(chosen).issubset(tests):
        raise ValueError("selected tests must be unique, sorted, tracked top-level specs")
    if type(manifest.get("total_tests")) is not int or manifest["total_tests"] != len(tests):
        raise ValueError("test inventory differs from the manifest")
    mode = manifest.get("mode")
    if mode not in ("full", "selected", "none") or (mode == "full" and chosen != tests):
        raise ValueError("invalid test selection mode")
    if (mode == "none" and chosen) or (mode == "selected" and (not chosen or chosen == tests)):
        raise ValueError("test selection mode disagrees with test list")
    if (not isinstance(manifest.get("changed_files"), list)
            or any(not isinstance(path, str) for path in manifest["changed_files"])
            or not isinstance(manifest.get("reasons"), list)
            or not manifest["reasons"] or any(not isinstance(reason, str) for reason in manifest["reasons"])):
        raise ValueError("selection must explain changed files and reasons")
    base = manifest.get("base_sha")
    if base is not None and (not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}", base)):
        raise ValueError("invalid selection base SHA")
    if mode != "full" and base is None:
        raise ValueError("partial test selection requires a base SHA")
    return chosen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--list", action="store_true", help="validate a manifest and print its test paths")
    args = parser.parse_args()
    if args.manifest:
        tests = validate(json.loads(args.manifest.read_text()))
        if args.list:
            print("\n".join(tests), end="\n" if tests else "")
    else:
        manifest = select(args.base, args.head)
        text = json.dumps(manifest, indent=2) + "\n"
        if args.out:
            args.out.write_text(text)
        else:
            print(text, end="")


if __name__ == "__main__":
    main()
