import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


STATE_DIRECTORY = Path(os.environ["MOCK_STATE_DIRECTORY"])
PORT = int(os.environ["MOCK_PORT"])


def response_object(model, status, output, usage):
    return {
        "id": "resp_codex_via_server_compat",
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "background": False,
        "error": None,
        "incomplete_details": None,
        "instructions": None,
        "max_output_tokens": None,
        "model": model,
        "output": output,
        "parallel_tool_calls": True,
        "previous_response_id": None,
        "reasoning": {"effort": None, "summary": None},
        "service_tier": "default",
        "store": False,
        "temperature": 1.0,
        "text": {"format": {"type": "text"}, "verbosity": "medium"},
        "tool_choice": "auto",
        "tools": [],
        "top_p": 1.0,
        "truncation": "disabled",
        "usage": usage,
        "user": None,
        "metadata": {},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.path != "/v1/responses":
            self.send_error(404)
            return

        body_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(body_length)
        request = json.loads(body)
        STATE_DIRECTORY.joinpath("request.json").write_text(json.dumps(request), encoding="utf-8")
        STATE_DIRECTORY.joinpath("headers.json").write_text(
            json.dumps({key.lower(): value for key, value in self.headers.items()}), encoding="utf-8"
        )
        model = request.get("model", "gpt-5.6-luna")
        item = {
            "id": "msg_codex_via_server_compat",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "OK", "annotations": [], "logprobs": []}],
        }
        usage = {
            "input_tokens": 10,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 1,
            "output_tokens_details": {"reasoning_tokens": 0},
            "total_tokens": 11,
        }
        events = [
            {"type": "response.created", "response": response_object(model, "in_progress", [], None)},
            {"type": "response.output_item.added", "output_index": 0, "item": {**item, "status": "in_progress", "content": []}},
            {"type": "response.content_part.added", "item_id": item["id"], "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": [], "logprobs": []}},
            {"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0, "content_index": 0, "delta": "OK", "logprobs": []},
            {"type": "response.output_text.done", "item_id": item["id"], "output_index": 0, "content_index": 0, "text": "OK", "logprobs": []},
            {"type": "response.content_part.done", "item_id": item["id"], "output_index": 0, "content_index": 0, "part": item["content"][0]},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": response_object(model, "completed", [item], usage)},
        ]

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for event in events:
            self.wfile.write(f"data: {json.dumps(event, separators=(',', ':'))}\n\n".encode("utf-8"))
            self.wfile.flush()
        self.close_connection = True

    def log_message(self, format, *args):
        return


STATE_DIRECTORY.mkdir(parents=True, exist_ok=True)
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
