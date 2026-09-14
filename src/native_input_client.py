"""Synchronous client for the native macOS keyboard-output gateway."""

from __future__ import annotations

import json
import os
import socket
import tempfile
import uuid
from pathlib import Path


class NativeInputError(RuntimeError):
    pass


class NativeInputClient:
    def __init__(self, socket_path: str | Path, timeout: float = 1.0) -> None:
        self.socket_path = str(socket_path)
        self.timeout = timeout

    @classmethod
    def from_environment(cls) -> "NativeInputClient | None":
        if os.environ.get("JOYHARNESS_INPUT_BACKEND", "").lower() != "native":
            return None
        path = os.environ.get("JOYHARNESS_NATIVE_INPUT_SOCKET")
        if not path:
            path = str(Path(tempfile.gettempdir()) / "joyharness-runtime" / "input.sock")
        return cls(path)

    def request(self, operation: str, **payload) -> dict:
        request_id = str(uuid.uuid4())
        request = {"id": request_id, "operation": operation, **payload}
        encoded = (json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(self.socket_path)
                connection.sendall(encoded)
                response_data = self._read_line(connection)
        except (OSError, TimeoutError) as error:
            raise NativeInputError(f"Native input gateway unavailable: {error}") from error

        try:
            response = json.loads(response_data)
        except json.JSONDecodeError as error:
            raise NativeInputError("Native input gateway returned invalid JSON") from error
        if response.get("id") != request_id or response.get("operation") != operation:
            raise NativeInputError("Native input gateway returned a mismatched response")
        if response.get("ok") is not True:
            raise NativeInputError(response.get("error") or "Native input gateway rejected the action")
        return response

    @staticmethod
    def _read_line(connection: socket.socket) -> str:
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                raise NativeInputError("Native input gateway closed without a response")
            chunks.append(chunk)
            size += len(chunk)
            if size > 65_536:
                raise NativeInputError("Native input response exceeded 64 KiB")
            joined = b"".join(chunks)
            if b"\n" in joined:
                return joined.split(b"\n", 1)[0].decode("utf-8")
