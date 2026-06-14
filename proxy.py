#!/usr/bin/env python3
"""
m3claude proxy — translates Anthropic /v1/messages to OpenAI /v1/chat/completions.

Listens on 127.0.0.1 (default port 8080, or OS-assigned if M3CLAUDE_PORT=0).
Reads the upstream API key from TOKENROUTER_API_KEY.

Env vars:
  TOKENROUTER_API_KEY   required — upstream API key
  M3CLAUDE_UPSTREAM     default: https://api.tokenrouter.com/v1
  M3CLAUDE_HOST         default: 127.0.0.1
  M3CLAUDE_PORT         default: 0 (OS-assigned)
  M3CLAUDE_PORT_FILE    if set, the chosen port is written to this file
  M3CLAUDE_LOG_LEVEL    default: 1 (0=errors, 1=info, 2=debug)

Supported endpoints:
  POST /v1/messages       translated Anthropic -> OpenAI chat completions
  GET  /v1/models         passthrough to upstream
  GET  /healthz           liveness probe
  other /v1/*             passthrough
"""
import json
import os
import sys
import time
import signal
import threading
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("M3CLAUDE_UPSTREAM", "https://api.tokenrouter.com").rstrip("/")
HOST = os.environ.get("M3CLAUDE_HOST", "127.0.0.1")
PORT = int(os.environ.get("M3CLAUDE_PORT", "0"))
API_KEY = os.environ.get("TOKENROUTER_API_KEY", "")
PORT_FILE = os.environ.get("M3CLAUDE_PORT_FILE", "")
LOG_LEVEL = int(os.environ.get("M3CLAUDE_LOG_LEVEL", "1"))

if not API_KEY:
    sys.stderr.write("m3claude-proxy: TOKENROUTER_API_KEY not set\n")
    sys.exit(2)


def log(level, msg):
    if LOG_LEVEL >= level:
        sys.stderr.write(f"[proxy] {msg}\n")
        sys.stderr.flush()


# ---------- Anthropic request -> OpenAI request ----------

def anthropic_to_openai(body):
    messages = []
    system = body.get("system")
    if system:
        if isinstance(system, str):
            messages.append({"role": "system", "content": system})
        elif isinstance(system, list):
            text = "".join(b.get("text", "") for b in system if b.get("type") == "text")
            if text:
                messages.append({"role": "system", "content": text})
    for m in body.get("messages", []):
        role = m.get("role")
        content = m.get("content")
        if isinstance(content, str):
            messages.append({"role": role, "content": content})
        elif isinstance(content, list):
            text = "".join(b.get("text", "") for b in content if b.get("type") == "text")
            messages.append({"role": role, "content": text})
    out = {
        "model": body.get("model", "MiniMax-M3"),
        "messages": messages,
        "stream": bool(body.get("stream", False)),
    }
    for k_in, k_out in (
        ("max_tokens", "max_tokens"),
        ("temperature", "temperature"),
        ("top_p", "top_p"),
        ("stop_sequences", "stop"),
        ("tools", "tools"),
        ("tool_choice", "tool_choice"),
    ):
        if k_in in body:
            out[k_out] = body[k_in]
    return out


# ---------- OpenAI response -> Anthropic response ----------

def openai_to_anthropic(resp, model):
    choices = resp.get("choices") or [{}]
    msg = choices[0].get("message", {}) if choices else {}
    text = msg.get("content", "") or ""
    finish = (choices[0].get("finish_reason") if choices else None) or "stop"
    stop_reason = {
        "stop": "end_turn",
        "length": "max_tokens",
        "tool_calls": "tool_use",
        "function_call": "tool_use",
    }.get(finish, "end_turn")
    usage = resp.get("usage") or {}
    return {
        "id": resp.get("id", "msg_proxy"),
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": text}],
        "model": model,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


# ---------- OpenAI SSE stream -> Anthropic SSE stream ----------

def sse_openai_to_anthropic(openai_sse_iter, model):
    msg_id = "msg_" + str(int(time.time() * 1000))
    yield "event: message_start\ndata: " + json.dumps({
        "type": "message_start",
        "message": {
            "id": msg_id, "type": "message", "role": "assistant",
            "content": [], "model": model,
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 0, "output_tokens": 0},
        },
    }) + "\n\n"
    yield "event: content_block_start\ndata: " + json.dumps({
        "type": "content_block_start", "index": 0,
        "content_block": {"type": "text", "text": ""},
    }) + "\n\n"
    final_finish = "end_turn"
    for raw in openai_sse_iter:
        if not raw:
            continue
        if raw.startswith(":"):
            continue
        if not raw.startswith("data:"):
            continue
        payload = raw[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            evt = json.loads(payload)
        except json.JSONDecodeError:
            continue
        for ch in (evt.get("choices") or []):
            delta = ch.get("delta") or {}
            piece = delta.get("content")
            if piece:
                yield "event: content_block_delta\ndata: " + json.dumps({
                    "type": "content_block_delta", "index": 0,
                    "delta": {"type": "text_delta", "text": piece},
                }) + "\n\n"
            fr = ch.get("finish_reason")
            if fr:
                final_finish = {
                    "stop": "end_turn",
                    "length": "max_tokens",
                    "tool_calls": "tool_use",
                }.get(fr, "end_turn")
    yield "event: content_block_stop\ndata: " + json.dumps({
        "type": "content_block_stop", "index": 0,
    }) + "\n\n"
    yield "event: message_delta\ndata: " + json.dumps({
        "type": "message_delta",
        "delta": {"stop_reason": final_finish, "stop_sequence": None},
    }) + "\n\n"
    yield "event: message_stop\ndata: " + json.dumps({"type": "message_stop"}) + "\n\n"


# ---------- HTTP handler ----------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_anthropic_error(self, code, message, err_type="api_error"):
        self._send_json(code, {"type": "error", "error": {"type": err_type, "message": message}})

    def do_GET(self):
        if self.path == "/healthz":
            self._send_json(200, {"status": "ok", "upstream": UPSTREAM})
            return
        self._passthrough("GET", b"")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError as e:
            return self._send_anthropic_error(400, f"Invalid JSON: {e}")
        if self.path == "/v1/messages":
            return self._handle_messages(body)
        return self._passthrough("POST", raw)

    def _handle_messages(self, body):
        model = body.get("model", "MiniMax-M3")
        stream = bool(body.get("stream", False))
        log(1, f"POST /v1/messages stream={stream} model={model}")
        openai_body = anthropic_to_openai(body)
        if stream:
            return self._stream_proxy("/v1/chat/completions", openai_body, model)
        return self._sync_proxy("/v1/chat/completions", openai_body, model)

    def _sync_proxy(self, path, body, model):
        req = urllib.request.Request(
            UPSTREAM + path,
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = resp.read()
                upstream = json.loads(data)
                anth = openai_to_anthropic(upstream, model)
                self._send_json(200, anth)
        except urllib.error.HTTPError as e:
            err_body = e.read()
            try:
                err = json.loads(err_body)
            except Exception:
                err = {}
            msg = (err.get("error", {}) or {}).get("message") if isinstance(err.get("error"), dict) else err.get("message")
            if not msg:
                msg = err_body.decode("utf-8", "replace") or f"Upstream {e.code}"
            self._send_anthropic_error(e.code, msg)
        except Exception as e:
            log(0, f"upstream error: {e}")
            self._send_anthropic_error(502, f"Upstream error: {e}")

    def _stream_proxy(self, path, body, model):
        req = urllib.request.Request(
            UPSTREAM + path,
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
            method="POST",
        )
        try:
            resp = urllib.request.urlopen(req, timeout=300)
        except urllib.error.HTTPError as e:
            # Upstream rejected the streaming request — translate the JSON error
            # envelope (OpenAI shape) into the Anthropic shape and return as
            # plain JSON, not SSE.
            err_body = e.read()
            try:
                err = json.loads(err_body)
            except Exception:
                err = {}
            msg = (err.get("error", {}) or {}).get("message") if isinstance(err.get("error"), dict) else err.get("message")
            if not msg:
                msg = err_body.decode("utf-8", "replace") or f"Upstream {e.code}"
            self._send_anthropic_error(e.code, msg)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            def line_iter():
                for raw in resp:
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    if line:
                        yield line
            for chunk in sse_openai_to_anthropic(line_iter(), model):
                self.wfile.write(chunk.encode("utf-8"))
                self.wfile.flush()
        except BrokenPipeError:
            pass
        except Exception as e:
            log(0, f"stream error: {e}")
        finally:
            try:
                resp.close()
            except Exception:
                pass

    def _passthrough(self, method, raw):
        url = UPSTREAM + self.path
        headers = {"Authorization": f"Bearer {API_KEY}"}
        if method == "POST":
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            url,
            data=raw if method == "POST" else None,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
                self.send_response(resp.status)
                ct = resp.headers.get("Content-Type", "application/octet-stream")
                self.send_header("Content-Type", ct)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            err_body = e.read()
            self.send_response(e.code)
            ct = e.headers.get("Content-Type", "application/json")
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(err_body)))
            self.end_headers()
            self.wfile.write(err_body)
        except Exception as e:
            self._send_anthropic_error(502, f"Passthrough error: {e}")


# ---------- main ----------

def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    actual_port = server.server_address[1]
    log(0, f"listening on {HOST}:{actual_port}, upstream={UPSTREAM}")
    if PORT_FILE:
        try:
            with open(PORT_FILE, "w") as f:
                f.write(str(actual_port))
        except OSError as e:
            log(0, f"could not write port file {PORT_FILE}: {e}")
    stopped = threading.Event()

    def shutdown(*_):
        if stopped.is_set():
            return
        stopped.set()
        log(0, "shutting down")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if PORT_FILE:
            try:
                os.unlink(PORT_FILE)
            except OSError:
                pass


if __name__ == "__main__":
    main()
