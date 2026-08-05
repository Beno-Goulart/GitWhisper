#!/usr/bin/env python3
# Unit tests for the GitWhisper Python engine.
#
# Run with:
#   python tests/test_engine.py          # whole suite
#   python -m unittest tests.test_engine -v
#
# Uses only the standard library. Tests that need git or a running HTTP
# server build their own fixtures in a temp directory.

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PYDIR = os.path.join(ROOT, "python")
sys.path.insert(0, PYDIR)

import config as config_mod  # noqa: E402
import detect  # noqa: E402
import llm  # noqa: E402
import message  # noqa: E402
import release_notes  # noqa: E402


def git(repo, *args, check=True):
    p = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if check and p.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (args, p.stderr))
    return p.stdout


def make_repo():
    d = tempfile.mkdtemp(prefix="gwtest-")
    git(d, "init", "-q")
    git(d, "config", "user.email", "test@example.com")
    git(d, "config", "user.name", "Test")
    git(d, "config", "commit.gpgsign", "false")
    return d


def write_file(repo, rel, content):
    path = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(content)
    return path


class MockOllamaHandler(BaseHTTPRequestHandler):
    response_text = "adds smart search to results"
    requests = []

    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.requests.append(("GET", self.path, ""))
        if self.path == "/api/tags":
            self._json(200, {"models": [{"name": "llama3.2"}]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length).decode("utf-8")
        self.requests.append(("POST", self.path, payload))
        if self.path == "/v1/chat/completions":
            self._json(200, {
                "choices": [{"message": {"content": self.response_text}}],
            })
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, *args):
        pass


class MockOllamaServer:
    def __init__(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MockOllamaHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.port = self.server.server_address[1]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        return False


class TestConfig(unittest.TestCase):
    def _write(self, content):
        d = tempfile.mkdtemp(prefix="gwcfg-")
        path = os.path.join(d, ".gitwhisperconfig")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        old = os.getcwd()
        os.chdir(d)
        self.addCleanup(os.chdir, old)
        return path

    def test_defaults(self):
        cfg = config_mod.Config()
        self.assertTrue(cfg.general_emoji)
        self.assertEqual(cfg.general_default, 1)
        self.assertEqual(cfg.gitmoji("feat"), "\u2728")
        self.assertEqual(cfg.release_title("feat"), "Features")

    def test_emoji_and_default(self):
        self._write("[general]\nemoji = false\ndefault = 3\n")
        cfg = config_mod.load_config()
        self.assertFalse(cfg.general_emoji)
        self.assertEqual(cfg.general_default, 3)

    def test_invalid_default_falls_back(self):
        self._write("[general]\ndefault = 99\n")
        self.assertEqual(config_mod.load_config().general_default, 1)

    def test_types_emoji_title_and_order(self):
        self._write(
            "[types]\nfeat = \U0001F680|Rocket Features\nsecurity = x|Security\n"
            "fix.order = 1\nsecurity.order = 2\n"
        )
        cfg = config_mod.load_config()
        self.assertEqual(cfg.gitmoji("feat"), "\U0001F680")
        self.assertEqual(cfg.release_title("feat"), "Rocket Features")
        self.assertIn("security", cfg.type_order)
        self.assertTrue(cfg.type_order.index("fix") < cfg.type_order.index("security"))

    def test_scope_map_and_forced_scope(self):
        self._write("[scope]\nsrc = api\n\n[general]\nscope = core\n")
        cfg = config_mod.load_config()
        self.assertEqual(cfg.scope_map["src"], "api")
        self.assertEqual(cfg.forced_scope, "core")

    def test_hooks_and_llm(self):
        self._write(
            "[hooks]\nprepare = false\nvalidate = true\n\n"
            "[llm]\nenabled = true\nurl = http://x/v1\nmodel = qwen2.5\n"
            "mode = full\ntimeout = 12\nmax_tokens = 99\napi_key = k\n"
        )
        cfg = config_mod.load_config()
        self.assertFalse(cfg.hooks_prepare)
        self.assertTrue(cfg.hooks_validate)
        self.assertTrue(cfg.llm_enabled)
        self.assertEqual(cfg.llm_url, "http://x/v1")
        self.assertEqual(cfg.llm_model, "qwen2.5")
        self.assertEqual(cfg.llm_mode, "full")
        self.assertEqual(cfg.llm_timeout, 12)
        self.assertEqual(cfg.llm_max_tokens, 99)
        self.assertEqual(cfg.llm_api_key, "k")


class TestDetect(unittest.TestCase):
    def test_single_added_js(self):
        r = detect.detect_commit_type(["app.js"], [], [], ["app.js"], [], [], "+console.log(1)")
        self.assertEqual(r["type"], "feat")
        self.assertEqual(r["desc"], "adds logging in app")

    def test_multiple_added(self):
        r = detect.detect_commit_type(["a.js", "b.js", "c.js"], [], [], ["a.js", "b.js", "c.js"], [], [], "+1")
        self.assertEqual(r["desc"], "adds 3 files")

    def test_modified_single_js(self):
        r = detect.detect_commit_type([], ["app.js"], [], [], ["app.js"], [], "-x\n+y")
        self.assertEqual(r["type"], "fix")
        self.assertEqual(r["desc"], "fixes app.js")

    def test_deleted_single_doc(self):
        r = detect.detect_commit_type([], [], ["README.md"], [], [], ["readme.md"], "-content")
        self.assertEqual(r["type"], "docs")
        self.assertEqual(r["desc"], "removes README.md")

    def test_migration_creates_table(self):
        r = detect.detect_commit_type(
            ["src/migrations/001_users.sql"], [], [],
            ["src/migrations/001_users.sql"], [], [],
            "+CREATE TABLE users (id INT PRIMARY KEY);",
        )
        self.assertEqual(r["type"], "feat")
        self.assertEqual(r["desc"], "adds migration for users")
        self.assertTrue(r["strong"])

    def test_ci_file(self):
        r = detect.detect_commit_type([".github/workflows/ci.yml"], [], [], [".github/workflows/ci.yml"], [], [], "+on: push")
        self.assertEqual(r["type"], "ci")

    def test_config_file(self):
        r = detect.detect_commit_type(["package.json"], [], [], ["package.json"], [], [], '+"scripts": {"x": "y"}')
        self.assertEqual(r["type"], "build")

    def test_style_file(self):
        r = detect.detect_commit_type(["style.css"], [], [], ["style.css"], [], [], "+body {}")
        self.assertEqual(r["type"], "style")

    def test_self_script_noise_is_stripped(self):
        added = ["gitwhisper.sh"]
        diff = (
            '+echo "literal feat fix docs build ci style refactor perf"\n'
            "+GITMOJI[perf]=\"x\""
        )
        r = detect.detect_commit_type(added, [], [], [a.lower() for a in added], [], [], diff, self_script=True)
        self.assertNotEqual(r["type"], "perf")

    def test_remove_literal_strings(self):
        out = detect.remove_literal_strings('+echo "perf cache memo"\n+x="feat fix docs"')
        self.assertNotIn("perf", out)
        self.assertNotIn("feat", out)

    def test_scope_from_files(self):
        self.assertEqual(detect.get_scope(["src/a.js", "src/b.js"]), "src")
        self.assertEqual(detect.get_scope(["app.js"]), "app")

    def test_github_username(self):
        self.assertEqual(detect.get_github_username("jdoe", "jdoe@users.noreply.github.com"), "jdoe")
        self.assertEqual(detect.get_github_username("@alice", "a@b.com"), "alice")
        self.assertEqual(detect.get_github_username("", "a@b.com"), "")


class TestMessage(unittest.TestCase):
    def _msg(self, added, modified, deleted, diff, cfg=None):
        cfg = cfg or config_mod.Config()
        return message.compute_message(diff, added, modified, deleted, cfg)

    def test_simple_default(self):
        m = self._msg(["app.js"], [], [], "+console.log(1)")
        self.assertEqual(m["title"], "\u2728 feat(app): adds logging in app")

    def test_default3_detailed_mix(self):
        cfg = config_mod.Config()
        cfg.general_default = 3
        m = self._msg(["app.js"], [], [], "+console.log(1)", cfg)
        self.assertEqual(m["title"], "\u2728 feat(app): updates scripts (app)")

    def test_multiple_added_count(self):
        m = self._msg(["a.js", "b.js", "c.js"], [], [], "+1")
        self.assertEqual(m["title"], "\u2728 feat: adds 3 files")

    def test_forced_scope(self):
        cfg = config_mod.Config()
        cfg.forced_scope = "core"
        m = self._msg(["app.js"], [], [], "+console.log(1)", cfg)
        self.assertEqual(m["title"], "\u2728 feat(core): adds logging in app")

    def test_scope_map(self):
        cfg = config_mod.Config()
        cfg.scope_map = {"src": "api"}
        m = self._msg(["src/thing.js"], [], [], "+const x = 1", cfg)
        self.assertEqual(m["title"], "\u2728 feat(api): adds x in thing")

    def test_emoji_off(self):
        cfg = config_mod.Config()
        cfg.general_emoji = False
        m = self._msg(["app.js"], [], [], "+console.log(1)", cfg)
        self.assertEqual(m["title"], "feat(app): adds logging in app")

    def test_body(self):
        m = self._msg(["a.js", "b.js"], [], [], "+1")
        self.assertIn("Added:", m["body"])
        self.assertIn("  - a.js", m["body"])
        self.assertIn("Change summary:", m["body"])

    def test_render_variants(self):
        cfg = config_mod.Config()
        m = self._msg(["app.js"], [], [], "+console.log(1)", cfg)
        variants, title = message.render_variants(m, "adds fuzzy matching")
        self.assertEqual(variants["simple_with_emoji"], "\u2728 feat(app): adds fuzzy matching")
        self.assertEqual(variants["detail_with_emoji"], "\u2728 feat(app): updates scripts (app)")
        self.assertEqual(title, "\u2728 feat(app): adds fuzzy matching")

    def test_branch_type_override(self):
        repo = make_repo()
        old = os.getcwd()
        os.chdir(repo)
        try:
            git(repo, "checkout", "-q", "-b", "feat/login")
            cfg = config_mod.Config()
            m = self._msg(["login.js"], [], [], "-x\n+y", cfg)
            self.assertEqual(m["type"], "feat")
        finally:
            os.chdir(old)


class TestReleaseNotes(unittest.TestCase):
    def test_bump_version(self):
        self.assertEqual(release_notes.bump_version("0.9.1", True, True, True), "1.0.0")
        self.assertEqual(release_notes.bump_version("0.9.1", False, True, True), "0.10.0")
        self.assertEqual(release_notes.bump_version("0.9.1", False, False, True), "0.9.2")
        self.assertEqual(release_notes.bump_version("0.9.1", False, False, False), "0.9.1")
        self.assertEqual(release_notes.bump_version("0.9.1", False, False, False, "major"), "1.0.0")
        self.assertEqual(release_notes.bump_version("0.9.1", False, False, False, "", "9.9.9"), "9.9.9")

    def test_parse_commit_log(self):
        log = "abc1234|feat(api): add login endpoint (#42)|2026-01-01|Test|test@example.com"
        commits = release_notes.parse_commit_log(log)
        self.assertEqual(len(commits), 1)
        c = commits[0]
        self.assertEqual(c["type"], "feat")
        self.assertEqual(c["scope"], "api")
        self.assertEqual(c["description"], "add login endpoint")
        self.assertEqual(c["pr"], "42")
        self.assertEqual(c["hash"], "abc1234")

    def test_parse_commit_log_skips_non_conventional(self):
        log = "abc1234|random message|2026-01-01|Test|test@example.com"
        self.assertEqual(release_notes.parse_commit_log(log), [])

    def test_format_bullet(self):
        self.assertEqual(release_notes.format_bullet({"description": "x"}), "- x")
        self.assertEqual(release_notes.format_bullet({"description": "x", "pr": "7"}), "- x (#7)")


class TestLlm(unittest.TestCase):
    def test_reachable(self):
        with MockOllamaServer() as srv:
            self.assertTrue(llm.ollama_reachable("http://127.0.0.1:%d" % srv.port))

    def test_unreachable(self):
        # pick a port nobody listens on
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        self.assertFalse(llm.ollama_reachable("http://127.0.0.1:%d" % port))

    def _cfg(self, srv, enabled=True, mode="description"):
        cfg = config_mod.Config()
        cfg.llm_enabled = enabled
        cfg.llm_url = "http://127.0.0.1:%d/v1" % srv.port
        cfg.llm_model = "llama3.2"
        cfg.llm_mode = mode
        cfg.llm_timeout = 5
        return cfg

    def test_suggest_description_mode(self):
        with MockOllamaServer() as srv:
            MockOllamaHandler.response_text = "adds smart search to results"
            cfg = self._cfg(srv)
            m = message.compute_message("+x", ["app.js"], [], [], cfg)
            title, body = llm.suggest(cfg, ["app.js"], [], [], "+x", m)
            self.assertIsNotNone(title)
            self.assertIn("adds smart search to results", title)
            self.assertEqual(title.split(": ")[0], "\u2728 feat(app)")
            self.assertIn("Added:", body)
            # the request must be OpenAI-compatible
            post = [r for r in MockOllamaHandler.requests if r[0] == "POST"]
            self.assertTrue(post)
            payload = json.loads(post[0][2])
            self.assertEqual(payload["model"], "llama3.2")
            self.assertIn("messages", payload)

    def test_suggest_full_mode(self):
        with MockOllamaServer() as srv:
            MockOllamaHandler.response_text = "feat(api): add endpoint\n\n- adds handler\n- wires route"
            cfg = self._cfg(srv, mode="full")
            m = message.compute_message("+x", ["app.js"], [], [], cfg)
            title, body = llm.suggest(cfg, ["app.js"], [], [], "+x", m)
            self.assertEqual(title, "feat(api): add endpoint")
            self.assertIn("- adds handler", body)

    def test_suggest_disabled(self):
        with MockOllamaServer() as srv:
            cfg = self._cfg(srv, enabled=False)
            title, body = llm.suggest(cfg, ["app.js"], [], [], "+x", None)
            self.assertIsNone(title)
            self.assertIsNone(body)

    def test_fallback_when_server_down(self):
        # enabled but unreachable -> silent (None, None), not an exception
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        cfg = config_mod.Config()
        cfg.llm_enabled = True
        cfg.llm_url = "http://127.0.0.1:%d/v1" % port
        cfg.llm_timeout = 1
        title, body = llm.suggest(cfg, ["app.js"], [], [], "+x", None)
        self.assertIsNone(title)
        self.assertIsNone(body)


class TestCli(unittest.TestCase):
    def _run_main(self, argv, cwd):
        old = os.getcwd()
        os.chdir(cwd)
        try:
            import io
            from contextlib import redirect_stdout
            import main as main_mod
            buf = io.StringIO()
            with redirect_stdout(buf):
                code = main_mod.main(argv)
            return code, buf.getvalue()
        finally:
            os.chdir(old)

    def test_help(self):
        repo = make_repo()
        code, out = self._run_main(["help"], repo)
        self.assertEqual(code, 0)
        self.assertIn("gitwhisper init", out)

    def test_not_a_git_repository(self):
        d = tempfile.mkdtemp(prefix="gwnogit-")
        code, out = self._run_main(["suggest"], d)
        self.assertEqual(code, 1)
        self.assertIn("Not a git repository", out)

    def test_unknown_command(self):
        repo = make_repo()
        code, out = self._run_main(["bogus"], repo)
        # matches the original PS/sh behavior: print help and exit 0
        self.assertEqual(code, 0)
        self.assertIn("Unknown command", out)

    def test_suggest_end_to_end(self):
        repo = make_repo()
        write_file(repo, "app.js", "console.log(1)")
        git(repo, "add", "app.js")
        code, out = self._run_main(["suggest"], repo)
        self.assertEqual(code, 0)
        self.assertIn("feat(app)", out)
        self.assertIn("Added:", out)

    def test_suggest_with_llm(self):
        with MockOllamaServer() as srv:
            MockOllamaHandler.response_text = "adds live preview"
            repo = make_repo()
            write_file(repo, "app.js", "console.log(1)")
            git(repo, "add", "app.js")
            with open(os.path.join(repo, ".gitwhisperconfig"), "w", encoding="utf-8") as fh:
                fh.write("[llm]\nenabled = true\nurl = http://127.0.0.1:%d/v1\nmodel = llama3.2\nmode = description\ntimeout = 5\n" % srv.port)
            code, out = self._run_main(["suggest"], repo)
            self.assertEqual(code, 0)
            self.assertIn("adds live preview", out)

    def test_suggest_falls_back_with_unreachable_llm(self):
        import socket
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        repo = make_repo()
        write_file(repo, "app.js", "console.log(1)")
        git(repo, "add", "app.js")
        with open(os.path.join(repo, ".gitwhisperconfig"), "w", encoding="utf-8") as fh:
            fh.write("[llm]\nenabled = true\nurl = http://127.0.0.1:%d/v1\nmodel = llama3.2\ntimeout = 1\n" % port)
        code, out = self._run_main(["suggest"], repo)
        self.assertEqual(code, 0)
        self.assertIn("feat(app): adds logging in app", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
