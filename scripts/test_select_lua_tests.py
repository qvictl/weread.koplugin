#!/usr/bin/env python3
"""Git-backed affected-test selection and manifest integrity regressions."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

import select_lua_tests as selector


def release_unit_step(path=None):
    source = (path or Path(__file__).parents[1] / ".github/workflows/release-candidate.yml").read_text()
    match = re.search(r"      - name: Unit specs and release coverage gates\n        run: \|\n"
                      r"((?:          [^\n]*\n|\n)+)", source)
    if not match:
        raise AssertionError("release unit gate shell step is missing")
    return textwrap.dedent(match[1])


class SelectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("weread/lib/leaf.lua", "return {}\n")
        self.write("weread/lib/parent.lua", 'return require("weread.lib.leaf")\n')
        self.write("weread/lib/other.lua", "return {}\n")
        self.write("spec/affected_spec.lua", 'require("weread.lib.parent")\n')
        self.write("spec/unrelated_spec.lua", 'require("weread.lib.other")\n')
        self.base = self.save()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def write(self, path, contents):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def save(self):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--allow-empty", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def select(self, base=None):
        return selector.select(base or self.base, "HEAD", self.repo)

    def test_transitive_subset_and_head_validation(self):
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        head = self.save()
        result = self.select()
        self.assertEqual(result["mode"], "selected")
        self.assertEqual(result["tests"], ["spec/affected_spec.lua"])
        self.assertEqual(result["head_sha"], head)
        self.assertEqual(result["base_sha"], self.base)
        self.assertEqual(result["total_tests"], 2)
        self.assertEqual(selector.validate(result, self.repo), result["tests"])

    def test_old_graph_preserves_removed_import(self):
        self.write("weread/lib/parent.lua", "return {}\n")
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        self.assertEqual(self.select()["tests"], ["spec/affected_spec.lua"])

    def test_rename_includes_removed_and_added_names(self):
        (self.repo / "weread/lib/leaf.lua").rename(self.repo / "weread/lib/moved.lua")
        self.write("weread/lib/parent.lua", 'return require("weread.lib.moved")\n')
        self.save()
        result = self.select()
        self.assertIn("weread/lib/leaf.lua", result["changed_files"])
        self.assertIn("weread/lib/moved.lua", result["changed_files"])
        self.assertEqual(result["tests"], ["spec/affected_spec.lua"])

    def test_literal_call_and_fixture_reference_forms(self):
        for expression in ['pcall(require, "weread.lib.leaf")',
                           r'require("weread\x2elib\x2eleaf")',
                           r'require("\119eread.lib.leaf")',
                           'require "weread.lib.leaf"',
                           'require [[weread.lib.leaf]]',
                           'loadfile("./weread/lib/leaf.lua")',
                           'dofile("weread/lib/leaf.lua")',
                           'package.loaded["weread.lib.leaf"] = nil',
                           'package.preload["weread.lib.leaf"] = function() return {} end']:
            with self.subTest(expression=expression):
                self.write("spec/affected_spec.lua", expression + "\n")
                base = self.save()
                self.write("weread/lib/leaf.lua", "return { changed = true }\n")
                self.save()
                self.assertEqual(self.select(base)["tests"], ["spec/affected_spec.lua"])
                self.write("weread/lib/leaf.lua", "return {}\n")
                self.save()

    def test_directory_init_consumer_is_not_hidden_by_a_direct_consumer(self):
        self.write("weread/lib/package/init.lua", 'return require("weread.lib.leaf")\n')
        self.write("spec/unrelated_spec.lua", 'require("weread.lib.package")\n')
        self.write("spec/independent_spec.lua", 'require("weread.lib.other")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        result = self.select(base)
        self.assertEqual(result["mode"], "selected")
        self.assertEqual(result["tests"], ["spec/affected_spec.lua", "spec/unrelated_spec.lua"])

    def test_comments_do_not_create_dependency_edges(self):
        self.write("spec/unrelated_spec.lua", '-- require("weread.lib.leaf")\n'
                   '--[=[ require("weread.lib.leaf") ]=]\nrequire("weread.lib.other")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        self.assertEqual(self.select(base)["tests"], ["spec/affected_spec.lua"])

    def test_batched_git_sources_preserve_utf8_byte_lengths_and_newlines(self):
        self.write("weread/lib/leaf.lua", '-- 中文\nreturn { text = "进度" }\n')
        self.save()
        paths = ["spec/affected_spec.lua", "weread/lib/leaf.lua", "weread/lib/parent.lua"]
        actual = selector.sources_at(self.git("rev-parse", "HEAD"), paths, self.repo)
        for path in paths:
            self.assertEqual(actual[path], (self.repo / path).read_text())

    def test_unclassified_dynamic_import_falls_back_to_full(self):
        self.write("spec/affected_spec.lua", 'require(os.getenv("SUBJECT_MODULE"))\n')
        self.save()
        result = self.select()
        self.assertEqual(result["mode"], "full")
        self.assertTrue(any("unclassified_dynamic_import" in item for item in result["reasons"]))

    def test_dynamic_import_in_old_graph_also_falls_back(self):
        self.write("spec/affected_spec.lua", 'require(os.getenv("SUBJECT_MODULE"))\n')
        base = self.save()
        self.write("spec/affected_spec.lua", 'require("weread.lib.leaf")\n')
        self.save()
        self.assertEqual(self.select(base)["mode"], "full")

    def test_aliased_loader_is_not_silently_ignored(self):
        self.write("spec/affected_spec.lua", 'local load_subject = require\nload_subject("weread.lib.leaf")\n')
        self.save()
        result = self.select()
        self.assertEqual(result["mode"], "full")
        self.assertTrue(any("unclassified_loader_reference" in item for item in result["reasons"]))

    def test_global_loader_escape_cannot_hide_behind_a_matched_direct_consumer(self):
        for loader in ('_G.require', '_G["require"]', '_G["re" .. "quire"]'):
            with self.subTest(loader=loader):
                self.write("spec/unrelated_spec.lua", 'local suffix = "leaf"\n' + loader + '("weread.lib." .. suffix)\n')
                self.write("spec/independent_spec.lua", 'require("weread.lib.other")\n')
                base = self.save()
                self.write("weread/lib/leaf.lua", "return { changed = true }\n")
                self.save()
                selected = self.select(base)
                self.assertEqual(selected["mode"], "full")
                self.assertIn("spec/affected_spec.lua", selected["tests"])
                self.assertIn("spec/unrelated_spec.lua", selected["tests"], "computed consumer was omitted")
                self.write("weread/lib/leaf.lua", "return {}\n")
                self.save()

    def test_dynamic_package_lookup_selects_both_consumers_without_global_full_fallback(self):
        for cache in ('package.loaded["weread.lib." .. suffix]',
                      'package.preload["weread.lib." .. suffix]',
                      'package["loaded"]["weread.lib." .. suffix]',
                      'local cache = package.loaded\ncache["weread.lib." .. suffix]'):
            with self.subTest(cache=cache):
                self.write("spec/unrelated_spec.lua", 'local suffix = "leaf"\n' + cache + ' = nil\nrequire("weread.lib.other")\n')
                self.write("spec/independent_spec.lua", 'require("weread.lib.other")\n')
                base = self.save()
                self.write("weread/lib/leaf.lua", "return { changed = true }\n")
                self.save()
                selected = self.select(base)
                self.assertEqual(selected["mode"], "selected")
                self.assertEqual(selected["tests"], ["spec/affected_spec.lua", "spec/unrelated_spec.lua"])
                self.write("weread/lib/leaf.lua", "return {}\n")
                self.save()

    def test_global_literal_require_still_has_a_direct_dependency(self):
        self.write("spec/unrelated_spec.lua", '_G.require("weread.lib.leaf")\n')
        self.write("spec/independent_spec.lua", 'require("weread.lib.other")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        chosen = self.select(base)
        self.assertEqual(chosen["mode"], "selected")
        self.assertEqual(chosen["tests"], ["spec/affected_spec.lua", "spec/unrelated_spec.lua"])

    def test_menu_bounded_list_has_dependency_edges(self):
        source = ('for _i, module in ipairs({ "weread.lib.leaf", "weread.lib.other" }) do\n'
                  'local order = require(module)\nend\nreturn {}\n')
        self.write("weread/ui/menu.lua", source)
        self.write("spec/affected_spec.lua", 'require("weread.ui.menu")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        self.assertEqual(self.select(base)["mode"], "selected")
        self.assertEqual(self.select(base)["tests"], ["spec/affected_spec.lua"])
        self.write("weread/ui/menu.lua", source.replace('"weread.lib.leaf", "weread.lib.other"', 'computed'))
        self.save()
        self.assertEqual(self.select(base)["mode"], "full")

    def test_runtime_preload_list_is_a_dependency_and_unknown_override_is_full(self):
        self.write("weread/lib/runtime.lua", 'Runtime.PRELOAD_MODULES = { "weread.lib.leaf" }\n'
                   'for _i, name in ipairs(options.preload_modules or Runtime.PRELOAD_MODULES) do\n'
                   'local ok, err = pcall(require, name)\nend\nreturn {}\n')
        self.write("spec/affected_spec.lua", 'require("weread.lib.runtime")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        self.assertEqual(self.select(base)["tests"], ["spec/affected_spec.lua"])
        self.write("spec/affected_spec.lua", 'require("weread.lib.runtime")\noptions.preload_modules = computed\n')
        self.save()
        self.assertEqual(self.select(base)["mode"], "full")

    def test_production_change_with_no_test_is_full(self):
        self.write("weread/lib/new.lua", "return {}\n")
        self.save()
        self.assertEqual(self.select()["reasons"], ["production_change_without_matching_test"])
        self.assertEqual(self.select()["mode"], "full")

    def test_unmatched_production_file_is_not_hidden_by_another_matched_change(self):
        self.write("weread/lib/new.lua", "return {}\n")
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        self.assertEqual(self.select()["mode"], "full")

    def test_test_only_change_runs_that_test(self):
        self.write("spec/unrelated_spec.lua", 'require("weread.lib.other")\nassert(true)\n')
        self.save()
        self.assertEqual(self.select()["tests"], ["spec/unrelated_spec.lua"])

    def test_deleted_tests_never_enter_head_manifest(self):
        (self.repo / "spec/affected_spec.lua").unlink()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        self.assertEqual(self.select()["tests"], ["spec/unrelated_spec.lua"])
        self.assertEqual(self.select()["mode"], "full")

    def test_docs_and_it_only_changes_need_no_lua_units(self):
        self.write("README.md", "documentation\n")
        self.write("spec/emulator/scenarios/new.lua", 'dofile(os.getenv("SCENARIO"))\n')
        self.save()
        self.assertEqual(self.select()["mode"], "none")
        self.assertEqual(self.select()["tests"], [])

    def test_framework_change_is_full(self):
        for name in ("scripts/run_lua_specs.sh", ".luacov", ".ci/coverage-policy.json", ".github/workflows/ci.yml"):
            with self.subTest(name=name):
                self.write(name, "changed\n")
                self.save()
                self.assertEqual(self.select()["mode"], "full")

    def test_missing_base_and_manual_are_full(self):
        for base in (None, "0" * 40):
            self.assertEqual(selector.select(base, "HEAD", self.repo)["mode"], "full")

    def test_stale_manifest_and_injected_paths_are_rejected(self):
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        result = self.select()
        for field, value in (("head_sha", self.base), ("tests", ["../outside.lua"]),
                             ("tests", ["spec/affected_spec.lua", "spec/affected_spec.lua"]),
                             ("mode", "none"), ("total_tests", 1), ("schema_version", True)):
            with self.subTest(field=field, value=value):
                bad = dict(result, **{field: value})
                with self.assertRaises(ValueError):
                    selector.validate(bad, self.repo)

    @unittest.skipUnless(shutil.which("luajit"), "runner regression requires LuaJIT")
    def test_actual_runner_selected_passes_but_release_default_full_stops_on_unrelated_failure(self):
        # Execute unchanged production runner/selector in a small Git fixture;
        # the Lua process and its failing assertion are real.
        for name in ("run_lua_specs.sh", "select_lua_tests.py"):
            self.write("scripts/" + name, (Path(__file__).parent / name).read_text())
        self.write("spec/unrelated_spec.lua", 'error("unselected failure must block release")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        manifest = selector.select(base, "HEAD", self.repo)
        path = self.repo / "selection.json"
        path.write_text(json.dumps(manifest))
        env = dict(os.environ, LUAJIT_BIN=shutil.which("luajit"))
        command = ["bash", "scripts/run_lua_specs.sh"]
        selected = subprocess.run(command + ["--manifest", str(path)], cwd=self.repo,
                                  env=env, text=True, capture_output=True)
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertIn("spec/affected_spec.lua", selected.stdout)
        self.assertNotIn("spec/unrelated_spec.lua", selected.stdout)
        release = subprocess.run(command, cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertNotEqual(release.returncode, 0)
        self.assertIn("unselected failure must block release", release.stderr)
        manifest["head_sha"] = base
        path.write_text(json.dumps(manifest))
        stale = subprocess.run(command + ["--manifest", str(path)], cwd=self.repo,
                               env=env, text=True, capture_output=True)
        self.assertNotEqual(stale.returncode, 0)
        self.assertNotIn("==>", stale.stdout, "a stale manifest ran tests before validation")

    @unittest.skipUnless(shutil.which("luajit"), "coverage runner regression requires LuaJIT")
    def test_actual_coverage_runner_uses_same_manifest_and_release_full_failure_is_blocking(self):
        env = dict(os.environ, LUAJIT_BIN=shutil.which("luajit"))
        available = subprocess.run([env["LUAJIT_BIN"], "-e", 'require("luacov.runner")'],
                                   env=env, capture_output=True)
        if available.returncode:
            self.skipTest("LuaCov is required; the policy job runs this after installing LuaCov")
        for name in ("run_lua_specs.sh", "run_lua_coverage.sh", "select_lua_tests.py", "coverage_tools.py"):
            self.write("scripts/" + name, (Path(__file__).parent / name).read_text())
        self.write(".luacov", (Path(__file__).parents[1] / ".luacov").read_text())
        self.write(".gitignore", "coverage/\nselection.json\n")
        self.write("spec/unrelated_spec.lua", 'error("unselected failure must block release")\n')
        base = self.save()
        self.write("weread/lib/leaf.lua", "return { changed = true }\n")
        self.save()
        manifest = selector.select(base, "HEAD", self.repo)
        path = self.repo / "selection.json"
        path.write_text(json.dumps(manifest))
        command = ["bash", "scripts/run_lua_coverage.sh", "--manifest", str(path)]
        measured = subprocess.run(command, cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(measured.returncode, 0, measured.stderr)
        evidence = self.repo / "coverage/test-selection.json"
        self.assertEqual(json.loads(evidence.read_text()), manifest)
        self.assertEqual([item.stem for item in (self.repo / "coverage/parts").glob("*.log")],
                         ["affected_spec"])
        self.assertNotIn("Overall:", measured.stdout)
        previous = self.git("rev-parse", "HEAD")
        self.write("docs/note.md", "documentation\n")
        self.save()
        none = selector.select(previous, "HEAD", self.repo)
        path.write_text(json.dumps(none))
        empty = subprocess.run(command, cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(empty.returncode, 0, empty.stderr)
        self.assertEqual(none["mode"], "none")
        self.assertEqual(list((self.repo / "coverage/parts").glob("*.log")), [])
        shutil.rmtree(self.repo / "coverage")
        # Execute the actual workflow shell, rather than a separately written
        # imitation that could stay green after its normal full-UT guard vanished.
        env.update(RUNNER_TEMP=str(self.repo / "runner-temp"), GITHUB_WORKSPACE=str(self.repo))
        release = subprocess.run(["bash", "-c", release_unit_step()],
                                 cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertNotEqual(release.returncode, 0)
        self.assertIn("unselected failure must block release", release.stderr)
        self.assertFalse((self.repo / "coverage").exists(), "release ran advisory coverage after normal UT failed")


if __name__ == "__main__":
    unittest.main()
