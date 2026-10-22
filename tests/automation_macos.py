#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Integration checks against a real Turf WKWebView. Requires a macOS GUI session."""
import base64
import importlib.util
import json
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("turf_client", ROOT / "tools/turf-client.py")
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


def expect_error(path, method, params, code):
    try:
        client.request(path, method, params)
    except RuntimeError as error:
        assert json.loads(str(error))["code"] == code, error
    else:
        raise AssertionError(f"{method} should fail")


def main():
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/turf"
    with tempfile.TemporaryDirectory(prefix="turf-automation-", dir="/tmp") as directory:
        folder = Path(directory)
        page = folder / "fixture.html"
        page.write_text('<!doctype html><title>Automation fixture</title><h1 id="heading">Hello</h1><select size="3"><option>One</option><option>Two</option><option>Three</option></select>')
        path = folder / "control.sock"
        with (folder / "stderr.log").open("w+") as errors:
            process = subprocess.Popen([str(binary), "--automation-socket", str(path), str(page)], stdout=subprocess.PIPE, stderr=errors)
            try:
                deadline = time.monotonic() + 15
                while not path.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        errors.seek(0)
                        raise AssertionError("Turf did not start: " + errors.read())
                    time.sleep(0.05)
                assert path.stat().st_mode & 0o777 == 0o600
                info = client.request(path, "info")
                assert info["engine"] == "WKWebView" and info["protocolVersion"] == 1
                client.request(path, "navigate", {"url": page.as_uri()})
                result = client.request(path, "evaluate", {"expression": "({title: document.title, text: document.querySelector('h1').textContent})"})
                assert result == {"type": "object", "value": {"title": "Automation fixture", "text": "Hello"}}, result
                assert client.request(path, "evaluate", {"expression": "new Promise(resolve => setTimeout(() => resolve(42), 50))"})["value"] == 42
                assert client.request(path, "evaluate", {"expression": "undefined"}) == {"type": "undefined"}
                assert client.request(path, "evaluate", {"expression": "null"}) == {"type": "null", "value": None}
                expect_error(path, "evaluate", {"expression": "(() => { throw new Error('test'); })()"}, -32002)
                expect_error(path, "evaluate", {"expression": "(() => { const a = {}; a.self = a; return a; })()"}, -32002)
                expect_error(path, "unknown", {}, -32601)
                expect_error(path, "resize", {"width": True, "height": 100}, -32602)
                expect_error(path, "navigate", {"url": "relative.html"}, -32602)
                expect_error(path, "evaluate", {}, -32602)
                size = client.request(path, "resize", {"width": 420, "height": 320})
                assert size == {"width": 420, "height": 320}, size
                png = client.request(path, "screenshot")
                data = base64.b64decode(png["data"], validate=True)
                assert data.startswith(b"\x89PNG\r\n\x1a\n")
                assert struct.unpack(">II", data[16:24]) == (png["width"], png["height"])
                # Malformed requests cannot execute close; fragmented and pipelined lines work.
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(5)
                    connection.connect(str(path))
                    connection.sendall(b'{"jsonrpc":"2.0","id":true,"method":"close"}\nnot json\n')
                    stream = connection.makefile("rb")
                    assert json.loads(stream.readline())["error"]["code"] == -32600
                    assert json.loads(stream.readline())["error"]["code"] == -32700
                    connection.sendall(b'{"jsonrpc":"2.0","id":"fragment",')
                    connection.sendall(b'"method":"info"}\n{"jsonrpc":"2.0","id":2,"method":"info"}\n')
                    assert json.loads(stream.readline())["id"] == "fragment"
                    assert json.loads(stream.readline())["id"] == 2
                    stream.close()
                # An unresolved evaluation times out without blocking the UI or later requests.
                started = time.monotonic()
                expect_error(path, "evaluate", {"expression": "new Promise(resolve => setTimeout(() => resolve(9), 31000))"}, -32001)
                assert 29 <= time.monotonic() - started < 35
                assert client.request(path, "evaluate", {"expression": "6 * 7"})["value"] == 42
                time.sleep(1.2)  # The old evaluation completes after its timeout.
                assert client.request(path, "info")["engine"] == "WKWebView"
                assert client.request(path, "close") == {"closing": True}
                assert process.wait(timeout=10) == 0
                assert not path.exists(), "Socket was not cleaned up"
                assert process.stdout.read() == b"", "Normal startup should remain quiet"
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
        # A preexisting disposable file must never be removed by socket setup.
        path.write_text("keep this test file")
        result = subprocess.run([str(binary), "--automation-socket", str(path)], capture_output=True, timeout=10)
        assert result.returncode != 0
        assert path.read_text() == "keep this test file"
    print("Passed real WKWebView automation, protocol, PNG, and safe-path checks.")


if __name__ == "__main__":
    main()
