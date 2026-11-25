"""Run on macOS after swift build -c release: python3 Tests/test_cli.py"""

import json
import os
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest


BINARY = Path(__file__).resolve().parents[1] / ".build/release/AskAI"


class FixtureServer(ThreadingHTTPServer):
    request_queue_size = 16


class FixtureAPI(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        question = request["messages"][-1]["content"]
        if self.server.barrier:
            self.server.barrier.wait(timeout=10)
        if self.server.status == 200 and request.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for piece in (question[:2], question[2:5], question[5:]):
                event = json.dumps({"choices": [{"delta": {"content": piece}}]}).encode()
                self.wfile.write(b"data: " + event + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        if self.server.status == 200:
            body = {"choices": [{"message": {"content": question}}]}
        else:
            body = {"error": {"message": "fixture rejected the request"}}
        reply = json.dumps(body).encode()
        self.send_response(self.server.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


class CLITests(unittest.TestCase):
    def setUp(self):
        profile = tempfile.TemporaryDirectory()
        self.addCleanup(profile.cleanup)
        self.history = Path(profile.name) / "Library/Application Support/AskAI/history.json"
        self.env = dict(os.environ, CFFIXED_USER_HOME=profile.name, ASKAI_KEY="fixture")
        self.server = FixtureServer(("127.0.0.1", 0), FixtureAPI)
        self.server.barrier = None
        self.server.status = 200
        self.addCleanup(self.server.server_close)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)

    def cli(self, *args, base_url=None):
        url = base_url or f"http://127.0.0.1:{self.server.server_port}"
        return subprocess.run([BINARY, "-lang", "en", "-baseURL", url, *args],
                              capture_output=True, text=True, env=self.env, timeout=20)

    def ask(self, question):
        return self.cli("--ask", question)

    def test_http_failure(self):
        self.server.status = 401
        result = self.ask("question")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("401", result.stderr)
        self.assertFalse(self.history.exists())

    def test_missing_key(self):
        self.env["ASKAI_KEY"] = ""
        # A remote endpoint without a key is refused before any request goes out.
        result = self.cli("--ask", "question", base_url="https://fixture.invalid/chat/completions")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("No API key", result.stderr)

    def test_local_endpoint_needs_no_key(self):
        # Ollama, LM Studio and the like have no key: the loopback fixture must work without one.
        self.env["ASKAI_KEY"] = ""
        result = self.ask("question")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "question")

    def test_missing_question(self):
        result = self.cli("--ask")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("--ask", result.stderr)

    def test_check_reports_hotkeys(self):
        result = self.cli("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hotkey           : ⌘⇧E", result.stdout)
        self.assertIn("direct ask key   : not set", result.stdout)
        self.assertIn("screen ask key   : not set", result.stdout)

        configured = self.cli(
            "-directAskHotkeyKey", "2",
            "-directAskHotkeyMods", str(1 << 20),
            "-directAskHotkeyDesc", "⌘D",
            "--check",
        )
        self.assertEqual(configured.returncode, 0, configured.stderr)
        self.assertIn("direct ask key   : ⌘D", configured.stdout)
        self.assertIn("screen ask key   : not set", configured.stdout)

    def test_success(self):
        result = self.ask("fixture answer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.splitlines()[0], "fixture answer")
        self.assertIn("json round-trip : ok", result.stdout)

    def test_history_can_be_switched_off(self):
        self.history.parent.mkdir(parents=True)
        self.history.write_text(json.dumps([dict(time=0, mode="explain", source="old", answer="saved")]))
        result = self.cli("-saveHistory", "NO", "--ask", "question")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "question")
        self.assertIn("history file : saving is disabled", result.stdout)
        # Existing entries are left alone and nothing is added.
        self.assertEqual([entry["source"] for entry in json.loads(self.history.read_text())], ["old"])

    def test_stream_prints_the_answer_once(self):
        # Three SSE pieces must come out as the answer, exactly once, and be saved once.
        result = self.cli("--ask", "streamed question", "--stream")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "streamed question")
        self.assertIn("json round-trip : ok", result.stdout)
        self.assertEqual([entry["source"] for entry in json.loads(self.history.read_text())],
                         ["streamed question"])

    def test_stream_without_a_question_is_a_usage_error(self):
        result = self.cli("--ask", "--stream")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("--ask", result.stderr)

    def test_concurrent_history(self):
        old = [dict(time=i, mode="explain", source=f"old-{i}", answer="saved")
               for i in reversed(range(20))]
        self.history.parent.mkdir(parents=True)
        self.history.write_text(json.dumps(old))

        questions = [f"question-{i}" for i in range(8)]
        self.server.barrier = threading.Barrier(len(questions))
        with ThreadPoolExecutor(max_workers=len(questions)) as pool:
            for question, result in zip(questions, pool.map(self.ask, questions)):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[0], question)

        history = json.loads(self.history.read_text())
        self.assertCountEqual([entry["source"] for entry in history[:8]], questions)
        self.assertEqual(history[8:], old[:12])
        self.assertEqual(stat.S_IMODE(self.history.stat().st_mode), 0o600)

    def assert_broken_history_is_moved_aside(self):
        """A history.json that cannot be read must not block every later save."""
        result = self.ask("question")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "question")
        self.assertIn("warning:", result.stderr)
        self.assertIn("history.corrupt-", result.stderr)
        # The answer is saved into a fresh, private history.json.
        self.assertEqual([entry["source"] for entry in json.loads(self.history.read_text())], ["question"])
        self.assertEqual(stat.S_IMODE(self.history.stat().st_mode), 0o600)
        # The unreadable original is kept next to it for the user to inspect.
        backups = list(self.history.parent.glob("history.corrupt-*.json"))
        self.assertEqual(len(backups), 1, backups)
        return backups[0]

    def test_truncated_history_is_moved_aside(self):
        self.history.parent.mkdir(parents=True)
        # e.g. a hand edit that was interrupted
        self.history.write_text('[{"time":0,"mode":"explain","source":"old","ans')
        self.assert_broken_history_is_moved_aside()

    def test_unreadable_history_is_moved_aside(self):
        self.history.parent.mkdir(parents=True)
        self.history.write_text(json.dumps([dict(time=0, mode="explain", source="old", answer="saved")]))
        self.history.chmod(0)
        backup = self.assert_broken_history_is_moved_aside()
        backup.chmod(0o600)   # so the temporary profile can be cleaned up


if __name__ == "__main__":
    unittest.main()
