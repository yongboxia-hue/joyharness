from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from src.native_input_client import NativeInputClient, NativeInputError


class FakeGateway:
    def __init__(self, socket_path: Path, *, ok: bool = True, mismatch: bool = False) -> None:
        self.socket_path = socket_path
        self.ok = ok
        self.mismatch = mismatch
        self.request: dict | None = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "FakeGateway":
        self.thread.start()
        self.ready.wait(timeout=1)
        return self

    def __exit__(self, *_args) -> None:
        self.thread.join(timeout=1)

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.socket_path))
            server.listen(1)
            self.ready.set()
            connection, _ = server.accept()
            with connection:
                payload = b""
                while b"\n" not in payload:
                    payload += connection.recv(4096)
                self.request = json.loads(payload.split(b"\n", 1)[0])
                response = {
                    "id": "wrong" if self.mismatch else self.request["id"],
                    "operation": self.request["operation"],
                    "ok": self.ok,
                    "error": None if self.ok else "rejected for test",
                }
                connection.sendall((json.dumps(response) + "\n").encode())


class NativeInputClientTests(unittest.TestCase):
    def test_request_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.sock"
            with FakeGateway(path) as gateway:
                NativeInputClient(path).request("combination", keys=["cmd", "v"], hold_ms=50)
            self.assertEqual(gateway.request["operation"], "combination")
            self.assertEqual(gateway.request["keys"], ["cmd", "v"])

    def test_rejection_and_mismatch_are_errors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rejected.sock"
            with FakeGateway(path, ok=False):
                with self.assertRaisesRegex(NativeInputError, "rejected for test"):
                    NativeInputClient(path).request("tap", key="a")

            mismatch = Path(directory) / "mismatch.sock"
            with FakeGateway(mismatch, mismatch=True):
                with self.assertRaisesRegex(NativeInputError, "mismatched"):
                    NativeInputClient(mismatch).request("ping")

    def test_environment_requires_explicit_native_backend(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(NativeInputClient.from_environment())
        with patch.dict(os.environ, {"JOYHARNESS_INPUT_BACKEND": "native"}, clear=True):
            client = NativeInputClient.from_environment()
            self.assertIsNotNone(client)
            self.assertTrue(client.socket_path.endswith("joyharness-runtime/input.sock"))


if __name__ == "__main__":
    unittest.main()
