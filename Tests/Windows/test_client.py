"""Exercise the real Windows form against an isolated loopback provider."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import subprocess
import sys
from threading import Thread


class Fixture(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        catalog = json.loads(Path("Shared/explain.json").read_text(encoding="utf-8"))
        design = next(p for p in catalog["profiles"] if p["en"] == "Design")
        assert self.headers["Authorization"] == "Bearer fixture-key"
        assert body["model"] == "fixture" and body["stream"]
        assert body["messages"] == [
            {"role": "system", "content": design["hintEn"] + "\n" + catalog["base"]["en"]},
            {"role": "user", "content": "kerning"},
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for part in ["fixture ", "answer"]:
            chunk = {"choices": [{"delta": {"content": part}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")


with HTTPServer(("127.0.0.1", 0), Fixture) as server:
    worker = Thread(target=server.serve_forever)
    worker.start()
    try:
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}/v1/chat/completions"],
                       check=True, timeout=30)
    finally:
        server.shutdown()
        worker.join()
