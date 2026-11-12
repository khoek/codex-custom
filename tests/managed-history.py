"""Exercise account-scoped history through the real CLI and broker protocol."""

import argparse
import array
import base64
import contextlib
import datetime
import fcntl
import http.server
import json
import os
import select
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


class Backend(http.server.BaseHTTPRequestHandler):
    def handle(self):
        # Clients cancel background metadata reads during shutdown.
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            super().handle()

    def do_GET(self):
        body = json.dumps({"models": []}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_GET

    def log_message(self, *_args):
        pass


def write_auth(path, user, account):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    token = ".".join(
        [
            encode({"alg": "none", "typ": "JWT"}),
            encode(
                {
                    "https://api.openai.com/auth": {
                        "chatgpt_user_id": user,
                        "chatgpt_account_id": account,
                        "chatgpt_plan_type": "pro",
                    }
                }
            ),
            "c2lnbmF0dXJl",
        ]
    )
    path.write_text(
        json.dumps(
            {
                "auth_mode": "chatgpt",
                "tokens": {
                    "id_token": token,
                    "access_token": token,
                    "refresh_token": "fixture-refresh",
                    "account_id": account,
                },
                "last_refresh": datetime.datetime.now(datetime.UTC).isoformat(),
            }
        )
    )
    path.chmod(0o600)


def write_rollout(home, index, user, account, paginated):
    thread_id = str(uuid.uuid4())
    stamp = f"2025-01-05T12-{index:02d}-00"
    timestamp = f"2025-01-05T12:{index:02d}:00Z"
    path = home / "sessions/2025/01/05" / f"rollout-{stamp}-{thread_id}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    meta = {
        "id": thread_id,
        "session_id": thread_id,
        "timestamp": timestamp,
        "cwd": str(home),
        "originator": "codex",
        "cli_version": "0.0.0",
        "source": "cli",
        "model_provider": "mock",
        "history_mode": "paginated" if paginated else "legacy",
    }
    if user is not None:
        meta.update(
            account_scoped=True, creator_user_id=user, creator_account_id=account
        )
    lines = [
        {"type": "session_meta", "payload": meta},
        {
            "type": "response_item",
            "payload": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "history needle"}],
            },
        },
        {
            "type": "event_msg",
            "payload": {
                "type": "user_message",
                "message": "history needle",
                "kind": "plain",
            },
        },
    ]
    for ordinal, line in enumerate(lines):
        line["timestamp"] = timestamp
        if paginated:
            line["ordinal"] = ordinal
    path.write_text("".join(json.dumps(line) + "\n" for line in lines))
    return thread_id, path, path.read_bytes().splitlines()[0]


class AppServer:
    def __init__(self, binary, home, slot=None, mode="shared"):
        self.stack = contextlib.ExitStack()
        self.buffer = b""
        self.request_id = 0
        try:
            args = [str(binary), "app-server"]
            if slot is not None:
                listener = self.stack.enter_context(socket.socket(socket.AF_UNIX))
                listener.settimeout(20)
                socket_path = slot / "startup.sock"
                socket_path.unlink(missing_ok=True)
                listener.bind(str(socket_path))
                listener.listen(1)
                nonce = "deadbeef" * 8
                lock = self.stack.enter_context((slot / "use.lock").open("rb"))
                fcntl.flock(lock, fcntl.LOCK_SH if mode == "shared" else fcntl.LOCK_EX)
                for flag, value in {
                    "auth-file": slot / "auth.json",
                    "credential-protocol-version": "2",
                    "credential-use-lock": slot / "use.lock",
                    "credential-use-lock-mode": mode,
                    "credential-mutation-lock": slot / "mutation.lock",
                    "credential-startup-socket": socket_path,
                    "credential-startup-nonce": nonce,
                }.items():
                    args.extend(["--" + flag, str(value)])
            env = {
                key: value
                for key, value in os.environ.items()
                if key
                not in {
                    "OPENAI_API_KEY",
                    "CODEX_API_KEY",
                    "CODEX_ACCESS_TOKEN",
                    "OPENAI_FEDERATION_RULE_ID",
                    "OPENAI_IDENTITY_TOKEN_FILE",
                    "OPENAI_WORKLOAD_IDENTITY_CONTEXT",
                    "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
                }
            }
            env.update(
                CODEX_HOME=str(home),
                CODEX_SQLITE_HOME=str(home),
                CODEX_APP_SERVER_MANAGED_CONFIG_PATH=str(home / "managed_config.toml"),
            )
            self.stderr = self.stack.enter_context(tempfile.TemporaryFile())  # noqa: SIM115
            self.process = subprocess.Popen(
                args,
                cwd=home,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.stderr,
                bufsize=0,
            )
            self.stack.callback(self.stop)
            if slot is not None:
                with listener.accept()[0] as stream:
                    stream.settimeout(20)
                    frame = b""
                    while not frame.endswith(b"\n"):
                        chunk = stream.recv(128)
                        assert chunk, "broker client disconnected before READY"
                        frame += chunk
                    assert frame == f"READY {nonce}\n".encode(), frame
                    stream.sendmsg(
                        [f"GO {nonce}\n".encode()],
                        [
                            (
                                socket.SOL_SOCKET,
                                socket.SCM_RIGHTS,
                                array.array("i", [lock.fileno()]),
                            )
                        ],
                    )
            self.call(
                "initialize",
                {
                    "clientInfo": {"name": "codex-tui", "version": "0.0.0"},
                    "capabilities": {"experimentalApi": True},
                },
            )
            self.send({"method": "initialized"})
        except BaseException:
            self.stack.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.stack.close()

    def stop(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")

    def call(self, method, params):
        self.request_id += 1
        self.send({"id": self.request_id, "method": method, "params": params})
        deadline = time.monotonic() + 30
        while True:
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if (
                    remaining <= 0
                    or not select.select(
                        [self.process.stdout], [], [], max(remaining, 0)
                    )[0]
                ):
                    self.stderr.seek(0)
                    raise AssertionError(
                        f"{method} timed out: {self.stderr.read().decode()}"
                    )
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    self.stderr.seek(0)
                    raise AssertionError(
                        f"app-server exited: {self.stderr.read().decode()}"
                    )
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == self.request_id:
                return response

    def ids(self, method, db_only=False):
        ids, cursor = [], None
        while True:
            params = {
                "currentAccountOnly": True,
                "limit": 1,
                "cursor": cursor,
                "modelProviders": [],
                "sortKey": "created_at",
            }
            if method == "thread/list":
                params["useStateDbOnly"] = db_only
            else:
                params["searchTerm"] = "needle"
            response = self.call(method, params)
            assert "result" in response, response
            page = response["result"]
            ids.extend(
                row["id"] if method == "thread/list" else row["thread"]["id"]
                for row in page["data"]
            )
            next_cursor = page.get("nextCursor")
            if next_cursor is None:
                assert len(ids) == len(set(ids)), "duplicate thread across pages"
                return set(ids)
            assert next_cursor != cursor, "repeated pagination cursor"
            cursor = next_cursor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True)
    args = parser.parse_args()
    binary = args.codex.resolve()
    with tempfile.TemporaryDirectory(prefix="codex-history-") as directory:
        home = Path(directory)
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend) as backend:
            worker = threading.Thread(target=backend.serve_forever, daemon=True)
            worker.start()
            try:
                url = f"http://127.0.0.1:{backend.server_port}"
                (home / "config.toml").write_text(f'''model = "mock-model"
model_provider = "mock"
chatgpt_base_url = "{url}"
cli_auth_credentials_store = "file"
[features]
cli_resume_account_check = true
background_paginated_rollout_migration = false
[model_providers.mock]
name = "mock"
base_url = "{url}/v1"
wire_api = "responses"
requires_openai_auth = false
''')
                fixtures = [
                    write_rollout(home, index, user, account, paginated)
                    for index, (user, account, paginated) in enumerate(
                        [
                            ("user-a", "team-a", False),
                            ("user-b", "team-b", True),
                            ("user-a", "other-team", True),
                            (None, None, False),
                        ]
                    )
                ]
                expected = {fixture[0] for fixture in fixtures}
                write_auth(home / "auth.json", "user-a", "team-a")
                with AppServer(binary, home) as server:
                    normal = {fixtures[0][0], fixtures[3][0]}
                    assert server.ids("thread/list") == normal, (
                        "ordinary login lost account filtering"
                    )
                    assert server.ids("thread/search") == normal, (
                        "ordinary search lost account filtering"
                    )
                    response = server.call(
                        "thread/resume",
                        {"threadId": fixtures[1][0], "excludeTurns": True},
                    )
                    assert "different ChatGPT account" in response.get("error", {}).get(
                        "message", ""
                    ), response
                slot = home / "slot"
                slot.mkdir(mode=0o700)
                for name in ("use.lock", "mutation.lock"):
                    (slot / name).touch(mode=0o600)
                for user, account, mode in [
                    ("user-a", "team-a", "shared"),
                    ("user-b", "team-b", "exclusive"),
                ]:
                    write_auth(slot / "auth.json", user, account)
                    with AppServer(binary, home, slot, mode) as server:
                        for method in ("thread/list", "thread/search"):
                            assert server.ids(method) == expected, (
                                f"managed {method} hid existing scoped history"
                            )
                        assert server.ids("thread/list", db_only=True) == expected, (
                            "state DB listing hid history"
                        )
                        for thread_id, path, header in fixtures:
                            for params in (
                                {"threadId": thread_id},
                                {"threadId": thread_id, "path": str(path)},
                            ):
                                response = server.call(
                                    "thread/resume", dict(params, excludeTurns=True)
                                )
                                assert (
                                    response.get("result", {})
                                    .get("thread", {})
                                    .get("id")
                                    == thread_id
                                ), response
                            assert path.read_bytes().splitlines()[0] == header, (
                                "creator metadata changed"
                            )
                print(
                    "PASS: managed list/search pagination, state DB listing, account rotation, shared/exclusive locks,"
                )
                print(
                    "      UUID/path/loaded resume, immutable metadata, and ordinary-login account isolation"
                )
            finally:
                backend.shutdown()
                worker.join()


if __name__ == "__main__":
    main()
