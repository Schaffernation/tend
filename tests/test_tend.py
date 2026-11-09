"""Tests for bin/tend.

Run them from the repository root:

    python3 -m unittest discover tests

The unit tests need nothing but Python. The end-to-end tests also need tmux,
and run against their own tmux server in a temporary folder, so they don't
touch your sessions. Without tmux, they're skipped.
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
TEND = ROOT / "bin" / "tend"


def load_tend(config):
    """Import bin/tend as a module, with its config at `config`."""
    os.environ["TEND_CONFIG"] = str(config)
    loader = importlib.machinery.SourceFileLoader("tend", str(TEND))
    spec = importlib.util.spec_from_loader("tend", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class TendTestCase(unittest.TestCase):
    """Gives each test its own config folder and a fresh copy of tend."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="tend-test-"))
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.config = self.dir / "config.json"
        self.tend = load_tend(self.config)


class TestNames(TendTestCase):
    def test_session_name_replaces_dots_and_colons(self):
        self.assertEqual(self.tend.session_name("my.app:v2"), "my-app-v2")

    def test_short_path_replaces_only_a_home_prefix(self):
        with mock.patch.object(self.tend, "HOME", Path("/Users/pat")):
            self.assertEqual(self.tend.short_path("/Users/pat/code"), "~/code")
            self.assertEqual(self.tend.short_path("/Users/pat"), "~")
            self.assertEqual(self.tend.short_path("/Users/patrick/code"), "/Users/patrick/code")
            self.assertEqual(self.tend.short_path("/Volumes/x/Users/pat"), "/Volumes/x/Users/pat")

    def test_split_command_survives_unbalanced_quotes(self):
        self.assertEqual(self.tend.split_command("echo 'hi"), ["echo", "'hi"])

    def test_is_shell(self):
        self.assertTrue(self.tend.is_shell("-zsh"))
        self.assertTrue(self.tend.is_shell("/bin/bash -l"))
        self.assertFalse(self.tend.is_shell("sleep 600"))
        self.assertFalse(self.tend.is_shell(""))


class TestApps(TendTestCase):
    def claude(self):
        return self.tend.app_by_id({"sessions": []}, "claude")

    def test_strip_flags_drops_flags_and_their_values(self):
        flags = {"-c": 0, "--session-id": 1}
        self.assertEqual(
            self.tend.strip_flags(["claude", "rc", "--session-id", "abc", "-c", "--name=x"], flags),
            ["claude", "rc", "--name=x"],
        )
        self.assertEqual(self.tend.strip_flags(["claude", "--session-id=abc", "rc"], flags), ["claude", "rc"])

    def test_pick_mode(self):
        app = self.claude()
        self.assertEqual(self.tend.pick_mode(app, ["claude", "rc"])["id"], "remote-control")
        self.assertEqual(self.tend.pick_mode(app, ["claude"])["id"], "interactive")
        self.assertEqual(self.tend.pick_mode({}, ["x"]), {})

    def test_fill_returns_none_when_a_field_is_missing(self):
        self.assertEqual(self.tend.fill("a {x}", {"x": 1}), "a 1")
        self.assertIsNone(self.tend.fill("a {y}", {"x": 1}))
        self.assertIsNone(self.tend.fill(None, {}))

    def test_describe_builds_resume_and_recover_commands(self):
        app = self.claude()
        proc = {"pid": 999999, "command": "claude rc --session-id old"}
        metadata = [
            {"_pid": 999999, "sessionId": "s1", "bridgeSessionId": "b1", "name": "chat", "status": "idle", "startedAt": 2},
            {"_pid": 1, "sessionId": "other", "bridgeSessionId": "b9", "startedAt": 1},
        ]
        info = self.tend.describe(app, proc, {999999}, metadata)
        self.assertEqual(info["command"], "claude rc")
        self.assertEqual(info["resume"], "claude rc")
        self.assertEqual(info["status"], "idle")
        self.assertEqual(
            info["conversations"],
            [{"id": "b1", "label": "chat", "recover": "claude --resume s1 --remote-control"}],
        )

    def test_describe_without_metadata_has_no_resume(self):
        info = self.tend.describe(self.claude(), {"pid": 999999, "command": "claude"}, {999999}, [])
        self.assertIsNone(info["resume"])
        self.assertEqual(info["conversations"], [])

    def test_matches_by_name_and_by_script(self):
        script = self.dir / "keepalive"
        script.write_text("#!/bin/sh\n")
        app = {"match": {"names": ["claude", "keepalive"]}}
        self.assertTrue(self.tend.matches(app, {"pid": 999999, "command": "/usr/local/bin/claude rc"}))
        self.assertTrue(self.tend.matches(app, {"pid": 999999, "command": f"sh {script}"}))
        self.assertFalse(self.tend.matches(app, {"pid": 999999, "command": "vim"}))

    def test_expected_app(self):
        cfg = {"sessions": []}
        self.assertEqual(self.tend.expected_app(cfg, "claude rc")["id"], "claude")
        self.assertIsNone(self.tend.expected_app(cfg, "sleep 5"))
        disabled = {"sessions": [], "apps": [{"id": "claude", "enabled": False}]}
        self.assertIsNone(self.tend.expected_app(disabled, "claude rc"))

    def test_your_app_overrides_a_builtin_field(self):
        apps = self.tend.apps({"sessions": [], "apps": [{"id": "claude", "launch": "claude"}, {"id": "x"}]})
        self.assertEqual(apps[0]["launch"], "claude")
        self.assertTrue(apps[0]["builtin"])
        self.assertEqual(apps[1], {"id": "x", "builtin": False, "enabled": True})

    def test_match_question_fills_in_the_text(self):
        question = self.tend.match_question(self.claude()["questions"], "Trust /tmp/p? [y/N] ")
        self.assertEqual(question["id"], "trust")
        self.assertIn("/tmp/p", question["text"])
        self.assertEqual([a["id"] for a in question["answers"]], ["yes", "no"])
        self.assertIsNone(self.tend.match_question(self.claude()["questions"], "$ "))

    def test_trusted_by_claude_includes_parent_folders(self):
        projects = {"/Users/pat/code": {"hasTrustDialogAccepted": True}}
        self.assertTrue(self.tend.trusted_by_claude("/Users/pat/code/app", projects))
        self.assertFalse(self.tend.trusted_by_claude("/Users/pat/other", projects))


class TestTerminalAndRecipes(TendTestCase):
    def test_applescript_string_keeps_non_ascii(self):
        self.assertEqual(self.tend.applescript_string('a "b" \\ café'), '"a \\"b\\" \\\\ café"')

    def test_attach_command_quotes_the_target(self):
        cfg = {"attach_command": "{tmux} attach -t {target} # {name}"}
        self.assertEqual(
            self.tend.attach_command(cfg, "my app", "/opt/homebrew/bin/tmux"),
            "/opt/homebrew/bin/tmux attach -t '=my app' # 'my app'",
        )

    def test_set_terminal_needs_a_target(self):
        cfg = {}
        self.tend.set_terminal(cfg, app="iterm", attach="control")
        self.assertEqual(cfg, {"terminal": "iTerm", "attach_command": self.tend.ATTACH_PRESETS["control"]})
        with self.assertRaises(self.tend.TendError):
            self.tend.set_terminal(cfg, attach="tmux attach")

    def test_recipe_input_is_quoted(self):
        command = self.tend.recipe_command({"sessions": []}, "clone", "https://x/y.git; rm -rf ~")
        self.assertEqual(command, "git clone 'https://x/y.git; rm -rf ~' .")
        with self.assertRaises(self.tend.TendError):
            self.tend.recipe_command({"sessions": []}, "clone", None)


class TestHistory(TendTestCase):
    def test_update_history_keeps_the_newest(self):
        history = {}
        for i in range(self.tend.HISTORY_LIMIT + 5):
            self.tend.update_history(history, {"s": [{"id": f"c{i}", "label": None}]}, now=i)
        entries = history["s"]
        self.assertEqual(len(entries), self.tend.HISTORY_LIMIT)
        self.assertEqual(entries[0]["id"], f"c{self.tend.HISTORY_LIMIT + 4}")

    def test_update_live_lists_a_conversation_a_restart_dropped(self):
        state = {}
        chat = {"id": "b1", "label": "chat", "recover": "claude --resume s1"}
        self.tend.update_live(state, {"s": {"pid": 10, "dir": "/p", "chats": [chat]}}, boot=1, now=100)
        self.assertEqual(state["dropped"], [])
        # The app came back as a new process, without the conversation.
        self.tend.update_live(state, {"s": {"pid": 11, "dir": "/p", "chats": []}}, boot=1, now=200)
        self.assertEqual([(d["session"], d["id"]) for d in state["dropped"]], [("s", "b1")])
        # It comes off the list once it runs again.
        self.tend.update_live(state, {"s": {"pid": 11, "dir": "/p", "chats": [chat]}}, boot=1, now=300)
        self.assertEqual(state["dropped"], [])

    def test_update_live_counts_a_reboot_as_a_restart(self):
        state = {}
        chat = {"id": "b1", "label": None, "recover": "r"}
        self.tend.update_live(state, {"s": {"pid": 10, "dir": "/p", "chats": [chat]}}, boot=1, now=0)
        self.tend.update_live(state, {"s": {"pid": 10, "dir": "/p", "chats": []}}, boot=2, now=1)
        self.assertEqual(len(state["dropped"]), 1)

    def test_dropped_entries_expire(self):
        state = {"dropped": [{"session": "s", "id": "b1", "dropped_at": 0}]}
        self.tend.update_live(state, {}, boot=1, now=self.tend.DROPPED_KEEP + 1)
        self.assertEqual(state["dropped"], [])

    def test_dropped_entry_reads_the_old_field_name(self):
        self.assertEqual(self.tend.dropped_entry({"service": "s", "id": "x"}), {"session": "s", "id": "x"})

    def test_dismiss(self):
        self.tend.save_state({"dropped": [{"session": "a", "id": "1"}, {"service": "b", "id": "2"}]})
        self.assertEqual(self.tend.dismiss("b", "2"), 1)
        self.assertEqual(self.tend.load_state()["dropped"], [{"session": "a", "id": "1"}])
        with self.assertRaises(self.tend.TendError):
            self.tend.dismiss("a", "nope")
        self.assertEqual(self.tend.dismiss(None, None), 1)


class TestConfigFiles(TendTestCase):
    def test_missing_config_gives_defaults(self):
        self.assertEqual(self.tend.load()["sessions"], [])

    def test_bad_json_is_a_tend_error(self):
        self.config.write_text("{bad")
        with self.assertRaisesRegex(self.tend.TendError, "isn't valid JSON"):
            self.tend.load()

    def test_old_services_key_is_read_and_written_back(self):
        self.config.write_text(json.dumps({"services": [{"name": "a", "dir": "/"}]}))
        cfg = self.tend.load()
        self.assertEqual(cfg["sessions"][0]["name"], "a")
        self.tend.save(cfg)
        saved = json.loads(self.config.read_text())
        self.assertIn("services", saved)
        self.assertNotIn("sessions", saved)

    def test_new_config_uses_sessions_key(self):
        with self.tend.edit_config() as cfg:
            cfg["sessions"].append({"name": "a", "dir": "/"})
        self.assertIn("sessions", json.loads(self.config.read_text()))

    def test_edit_config_saves_nothing_if_the_block_raises(self):
        with self.assertRaises(RuntimeError):
            with self.tend.edit_config() as cfg:
                cfg["sessions"].append({"name": "a", "dir": "/"})
                raise RuntimeError
        self.assertFalse(self.config.exists())

    def test_lock_is_reentrant(self):
        with self.tend.locked():
            with self.tend.edit_config() as cfg:
                cfg["terminal"] = "Terminal"
        self.assertEqual(self.tend.load()["terminal"], "Terminal")

    def test_concurrent_edits_are_all_kept(self):
        """Each process adds one session. Without the lock, some get lost."""
        child = textwrap.dedent(
            f"""
            import importlib.machinery, importlib.util, os, sys, time
            os.environ["TEND_CONFIG"] = {str(self.config)!r}
            loader = importlib.machinery.SourceFileLoader("tend", {str(TEND)!r})
            spec = importlib.util.spec_from_loader("tend", loader)
            tend = importlib.util.module_from_spec(spec)
            loader.exec_module(tend)
            with tend.edit_config() as cfg:
                time.sleep(0.02)
                cfg["sessions"].append({{"name": sys.argv[1], "dir": "/"}})
            """
        )
        procs = [subprocess.Popen([sys.executable, "-c", child, f"s{i}"]) for i in range(12)]
        for p in procs:
            self.assertEqual(p.wait(), 0)
        names = {s["name"] for s in self.tend.load()["sessions"]}
        self.assertEqual(names, {f"s{i}" for i in range(12)})

    def test_extend_path_keeps_your_order(self):
        with mock.patch.dict(os.environ, {"PATH": "/mine:/usr/bin"}):
            self.tend.extend_path()
            parts = os.environ["PATH"].split(os.pathsep)
        self.assertEqual(parts[:2], ["/mine", "/usr/bin"])
        self.assertIn("/opt/homebrew/bin", parts)
        self.assertEqual(parts.count("/usr/bin"), 1)


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
class TestEndToEnd(unittest.TestCase):
    """Runs the real CLI against its own tmux server."""

    def setUp(self):
        # tmux socket paths must be short, so use /tmp, not the system's
        # longer temporary folder.
        self.dir = Path(tempfile.mkdtemp(prefix="tt", dir="/tmp")).resolve()
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
        self.env.update(TMUX_TMPDIR=str(self.dir), TEND_CONFIG=str(self.dir / "config.json"))
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.addCleanup(subprocess.run, ["tmux", "kill-server"], env=self.env, capture_output=True)

    def tend(self, *args, check=True):
        r = subprocess.run([sys.executable, str(TEND), *args], env=self.env, capture_output=True, text=True)
        if check and r.returncode:
            self.fail(f"tend {' '.join(args)} failed ({r.returncode}): {r.stderr}")
        return r

    def rows(self):
        return {r["name"]: r for r in json.loads(self.tend("ls", "--json").stdout)}

    def eventually(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.25)
        self.fail("condition didn't become true in time")

    def test_new_restart_stop_and_rm(self):
        folder = self.dir / "my.project"
        out = self.tend("new", "--dir", str(folder), "--mkdir", "--", "sleep", "600").stdout
        self.assertIn("Started 'my-project'", out)
        self.eventually(lambda: self.rows()["my-project"]["state"] == "running")
        row = self.rows()["my-project"]
        self.assertTrue(row["managed"])
        self.assertTrue(row["named_after_dir"])
        self.assertEqual(row["command"], "sleep 600")

        # A second session in the same folder gets a free name.
        self.assertIn("my-project-2", self.tend("new", "--dir", str(folder), "--", "sleep", "600").stdout)

        self.tend("restart", "my-project")
        self.eventually(lambda: self.rows()["my-project"]["state"] == "running")
        self.tend("stop", "my-project")
        self.assertEqual(self.rows()["my-project"]["state"], "stopped")
        self.tend("rm", "my-project")
        self.assertNotIn("my-project", self.rows())

    def test_snapshot_tracks_a_session_started_without_a_shell(self):
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", "loose", "-c", str(self.dir), "sleep 700"],
            env=self.env,
            check=True,
        )
        self.eventually(lambda: self.rows()["loose"]["state"] == "running")
        self.assertIn("Tracking 'loose': sleep 700", self.tend("snapshot").stdout)
        self.assertTrue(self.rows()["loose"]["managed"])

    def test_restore_starts_stopped_sessions(self):
        self.tend("add", "a", "--dir", str(self.dir), "--", "sleep", "600")
        self.tend("add", "b", "--dir", str(self.dir), "--no-autostart", "--", "sleep", "600")
        self.tend("restore")
        rows = self.rows()
        self.assertNotEqual(rows["a"]["state"], "stopped")
        self.assertEqual(rows["b"]["state"], "stopped")

    def test_answer_types_into_a_waiting_app(self):
        fake = self.dir / "bin" / "claude"
        fake.parent.mkdir()
        fake.write_text("#!/bin/sh\nprintf 'Trust %s? [y/N] ' \"$PWD\"; read a; echo \"got $a\"; sleep 600\n")
        fake.chmod(0o755)
        self.tend("add", "q", "--dir", str(self.dir), "--start", "--", str(fake))
        r = self.tend("wait", "q", "--timeout", "15", check=False)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("Answered 'Trust'", self.tend("answer", "q", "yes").stdout)
        self.eventually(lambda: self.rows()["q"]["app"]["question"] is None)

    def test_errors_are_one_line(self):
        r = self.tend("start", "nosuch", check=False)
        self.assertEqual(r.returncode, 1)
        self.assertTrue(r.stderr.startswith("tend: no tracked session named 'nosuch'"))


if __name__ == "__main__":
    unittest.main()
