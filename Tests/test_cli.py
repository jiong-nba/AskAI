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
        reply = json.dumps({"choices": [{"message": {"content": question}}]}).encode()
        self.send_response(200)
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
        self.addCleanup(self.server.server_close)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)

    def ask(self, question):
        url = f"http://127.0.0.1:{self.server.server_port}"
        return subprocess.run([BINARY, "-lang", "en", "-baseURL", url, "--ask", question],
                              capture_output=True, text=True, env=self.env, timeout=20)

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


if __name__ == "__main__":
    unittest.main()
