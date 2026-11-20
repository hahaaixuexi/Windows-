#!/usr/bin/env python3
"""Local fake DingTalk robot used by tests/Simulate.ps1.

Usage: python MockDingTalk.py <port> <logfile>
Every request is appended to <logfile> as one JSON line.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG_PATH = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _record(self, body: bytes) -> None:
        entry = {
            "method": self.command,
            "path": self.path,
            "body": body.decode("utf-8", "replace"),
        }
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def _reply(self, payload: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        # Used as a fake "network is up" probe target.
        self._record(b"")
        self._reply(b'{"errcode":0,"errmsg":"ok"}')

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        self._record(body)
        self._reply(b'{"errcode":0,"errmsg":"ok"}')

    def log_message(self, *args) -> None:  # keep stdout clean
        pass


ThreadingHTTPServer.allow_reuse_address = True
server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
server.serve_forever()
