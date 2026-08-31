import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


EXPECTED_AUTHORIZATION = os.environ.get("EXPECTED_AUTHORIZATION", "Bearer test-upstream-key")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_body(self, status, content_type, body):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def is_authorized(self):
        return self.headers.get("Authorization") == EXPECTED_AUTHORIZATION

    def do_GET(self):
        if self.path == "/healthz":
            self.send_body(200, "text/plain", "ok")
            return

        if not self.is_authorized():
            self.send_body(401, "application/json", json.dumps({"authorized": False}))
            return

        if self.path == "/v1/models":
            self.send_body(200, "application/json", json.dumps({"authorized": True, "data": []}))
            return

        if self.path == "/v1/fail":
            self.send_body(503, "application/json", json.dumps({"error": "upstream unavailable"}))
            return

        self.send_body(200, "text/plain", "upstream path reached")

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)

        if not self.is_authorized():
            self.send_body(401, "application/json", json.dumps({"authorized": False}))
            return

        if self.path != "/v1/responses":
            self.send_body(404, "application/json", json.dumps({"error": "not found"}))
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b'data: {"type":"response.created"}\n\n')
        self.wfile.flush()
        time.sleep(0.05)
        completed = json.dumps({"type": "response.completed", "received_bytes": len(body)})
        self.wfile.write(f"data: {completed}\n\n".encode("utf-8"))
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, format, *args):
        return


ThreadingHTTPServer(("0.0.0.0", 8317), Handler).serve_forever()
