#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Integration checks against a real Turf WKWebView. Requires a macOS GUI session."""
import base64
import importlib.util
import json
import os
import hashlib
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


def feature_checks(path, folder, engine="WKWebView"):
    def evaluate(expression):
        return client.request(path, "evaluate", {"expression": expression}).get("value")
    def wait_for(expression):
        for _ in range(100):
            if evaluate(expression):
                return
            time.sleep(0.02)
        raise AssertionError(f"Condition did not become true: {expression}")
    def click(selector):
        point = evaluate(f"(() => {{const r=document.querySelector({json.dumps(selector)}).getBoundingClientRect(); return {{x:r.x+r.width/2,y:r.y+Math.min(10,r.height/2)}};}})()")
        evaluate("window.lastClickTarget = null")
        client.request(path, "click", point)
        wait_for(f"document.querySelector({json.dumps(selector)}).contains(window.lastClickTarget)")

    background_linux = engine == "WebKitGTK" and client.request(path, "info")["background"]
    if background_linux:
        expect_error(path, 'click', {'x': 10, 'y': 10}, -32004)
        expect_error(path, 'key', {'key': 'a'}, -32004)
        evaluate("document.querySelector('#editor').focus(); document.querySelector('#editor').value=''; window.inputLog=[]; document.addEventListener('input',e=>inputLog.push(e.isTrusted));")
        client.request(path, 'typeText', {'text': 'background 🦦 café'})
        wait_for("document.querySelector('#editor').value === 'background 🦦 café'")
        assert evaluate("inputLog.length > 0 && inputLog.every(Boolean)")
    else:
        evaluate("document.addEventListener('click',e=>window.lastClickTarget=e.target)")
        evaluate("window.inputLog=[]; for(const kind of ['click','keydown','keyup','input']) document.addEventListener(kind,e=>inputLog.push({kind,key:e.key,trusted:e.isTrusted,repeat:e.repeat})); document.querySelector('#button').onclick=()=>window.clicked=true;")
        click('#button')
        wait_for('window.clicked === true')
        assert evaluate("inputLog.some(e=>e.kind==='click' && e.trusted)")
        click('#choices')
        wait_for("document.activeElement.id === 'choices'")
        evaluate("document.querySelector('#choices').selectedIndex=0; inputLog=[]")
        client.request(path, 'key', {'key': 'ArrowDown'})
        wait_for("document.querySelector('#choices').selectedIndex > 0")
        assert evaluate("document.querySelector('#choices').selectedIndex") == 1, 'ArrowDown skipped an entry'
        assert evaluate("inputLog.filter(e=>e.kind==='keydown' && e.key==='ArrowDown').length") == 1
        assert evaluate("inputLog.filter(e=>e.kind==='keydown').every(e=>e.trusted)")
        if engine != 'WebKitGTK':
            client.request(path, 'key', {'key': 'ArrowDown', 'repeat': True})
        else:
            expect_error(path, 'key', {'key': 'ArrowDown', 'repeat': True}, -32004)
            client.request(path, 'key', {'key': 'ArrowDown'})
        wait_for("document.querySelector('#choices').selectedIndex === 2")
        if engine != "WebKitGTK":
            assert evaluate("inputLog.some(e=>e.kind==='keydown' && e.repeat)")
        client.request(path, 'key', {'key': 'ArrowUp'})
        wait_for("document.querySelector('#choices').selectedIndex === 1")
        click('#editor')
        wait_for("document.activeElement.id === 'editor'")
        evaluate("document.querySelector('#editor').setSelectionRange(0,0)")
        client.request(path, 'key', {'key': 'ArrowDown'})
        wait_for("document.querySelector('#editor').selectionStart > 0")
        assert evaluate("document.querySelector('#editor').selectionStart") == len('First line\n')
        client.request(path, 'key', {'key': 'ArrowRight', 'modifiers': ['shift']})
        wait_for("document.querySelector('#editor').selectionEnd > document.querySelector('#editor').selectionStart")
        assert evaluate("document.querySelector('#editor').selectionEnd-document.querySelector('#editor').selectionStart") == 1
        evaluate("document.querySelector('#editor').value=''; document.querySelector('#editor').setSelectionRange(0,0)")
        client.request(path, 'key', {'key': 'a'})
        wait_for("document.querySelector('#editor').value === 'a'")
        client.request(path, 'typeText', {'text': ' otter 🦦 café'})
        wait_for("document.querySelector('#editor').value === 'a otter 🦦 café'")
        client.request(path, 'key', {'key': 'a', 'modifiers': ['meta' if engine == 'WKWebView' else 'control']})
        wait_for("document.querySelector('#editor').selectionStart === 0 && document.querySelector('#editor').selectionEnd === document.querySelector('#editor').value.length")
        client.request(path, 'key', {'key': 'Backspace'})
        wait_for("document.querySelector('#editor').value === ''")
        client.request(path, 'key', {'key': '1', 'modifiers': ['shift']})
        client.request(path, 'key', {'key': 'Z'})
        client.request(path, 'key', {'key': '+'})
        wait_for("document.querySelector('#editor').value === '!Z+'");
        if engine == "WKWebView":
            client.request(path, 'key', {'key': '=', 'modifiers': ['meta']})
            wait_for("parseFloat(document.body.style.zoom) > 1")
            client.request(path, 'key', {'key': '0', 'modifiers': ['meta']})
            wait_for("parseFloat(document.body.style.zoom) === 1")
    expect_error(path, 'click', {'x': -1, 'y': 0}, -32602)
    expect_error(path, 'key', {'key': 'Unknown'}, -32602)
    expect_error(path, 'key', {'key': 'a', 'modifiers': ['unsupported']}, -32602)
    expect_error(path, 'key', {'key': 'a', 'repeat': 1}, -32602)
    # A payload larger than the entire response limit must still transfer intact.
    size = 33 * 1024 * 1024 + 17
    output = folder / 'large.bin'
    metadata = client.grab(path, f"new Blob([new Uint8Array({size}).fill(137)])", output)
    assert metadata['bytes'] == size and output.stat().st_size == size
    assert hashlib.sha256(output.read_bytes()).digest() == hashlib.sha256(bytes([137]) * size).digest()
    assert evaluate("Object.keys(window).filter(k=>k.startsWith('__turfGrab_')).length") == 0
    client.grab(path, "'data:text/plain;base64,b3R0ZXI='", output, chunk_bytes=2)
    assert output.read_bytes() == b'otter'
    try:
        client.grab(path, "(() => {throw new Error('test failure')})()", output)
    except RuntimeError:
        pass
    else:
        raise AssertionError('Failed preparation should report an error')
    assert output.read_bytes() == b'otter'
    original_request = client.request
    def interrupted_request(socket_path, method, params=None):
        if params and 'state.blob.slice(256,' in params.get('expression', ''):
            raise RuntimeError('Simulated transfer interruption')
        return original_request(socket_path, method, params)
    client.request = interrupted_request
    try:
        try:
            client.grab(path, 'new Uint8Array(1024)', output, chunk_bytes=128)
        except RuntimeError:
            pass
        else:
            raise AssertionError('Transfer interruption should report an error')
    finally:
        client.request = original_request
    assert output.read_bytes() == b'otter'
    assert not list(folder.glob('.large.bin.*'))
    assert evaluate("Object.keys(window).filter(k=>k.startsWith('__turfGrab_')).length") == 0


def run_checks(check_focus, engine="WKWebView", background=True):
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/turf"
    with tempfile.TemporaryDirectory(prefix="turf-automation-", dir="/tmp") as directory:
        folder = Path(directory)
        page = folder / "fixture.html"
        page.write_text('<!doctype html><title>Automation fixture</title><h1 id="heading">Hello</h1><select id="choices" size="3"><option>One</option><option>Two</option><option>Three</option></select><button id="button">Click</button><textarea id="editor" rows="8">First line\nSecond line\nThird line</textarea>')
        path = folder / "control.sock"
        with (folder / "stderr.log").open("w+") as errors:
            process = subprocess.Popen([str(binary), "--automation-socket", str(path), *(["--no-focus"] if background else []), str(page)], stdout=subprocess.PIPE, stderr=errors)
            try:
                deadline = time.monotonic() + 15
                while not path.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        errors.seek(0)
                        raise AssertionError("Turf did not start: " + errors.read())
                    time.sleep(0.05)
                assert path.stat().st_mode & 0o777 == 0o600
                info = client.request(path, "info")
                check_focus(process.pid, "startup")
                assert info["background"] is background
                assert info["engine"] == engine and info["protocolVersion"] == 1
                if engine == "WebKitGTK":
                    for _ in range(150):
                        if not client.request(path, "info")["loading"]:
                            break
                        time.sleep(0.1)
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
                feature_checks(path, folder, engine)
                check_focus(process.pid, "native input and grab")
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
                assert client.request(path, "info")["engine"] == engine
                assert client.request(path, "close") == {"closing": True}
                assert process.wait(timeout=10) == 0
                check_focus(process.pid, "shutdown")
                assert not path.exists(), "Socket was not cleaned up"
                assert process.stdout.read() == b"", "Normal startup should remain quiet"
            except BaseException:
                errors.flush()
                errors.seek(0)
                print(errors.read(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
        # A preexisting disposable file must never be removed by socket setup.
        path.write_text("keep this test file")
        result = subprocess.run([str(binary), "--automation-socket", str(path)], capture_output=True, timeout=10)
        assert result.returncode != 0
        assert path.read_text() == "keep this test file"
    print(f"Passed real {engine} automation, protocol, PNG, and safe-path checks.")


def main():
    # Observe the existing foreground app without activating a helper window.
    with tempfile.TemporaryDirectory(prefix="turf-focus-", dir="/tmp") as directory:
        folder = Path(directory)
        guard = folder / "guard"
        marker = folder / "focus"
        subprocess.run(["clang", "-fobjc-arc", "-framework", "Cocoa",
                        str(ROOT / "tests/automation_focus_guard.m"), "-o", str(guard)],
                       env={**os.environ, "TMPDIR": directory}, check=True)
        log = marker.open("w")
        process = subprocess.Popen([str(guard)], stdout=log)
        try:
            for _ in range(100):
                if marker.exists() and marker.stat().st_size:
                    break
                time.sleep(0.05)
            assert process.poll() is None, "Focus monitor exited"
            initial = json.loads(marker.read_text().splitlines()[0])
            print(f"Foreground before launch: {initial['name']} ({initial['pid']})", flush=True)
            def check_focus(pid, stage):
                time.sleep(0.05)
                assert process.poll() is None, "Focus monitor exited"
                entries = [json.loads(line) for line in marker.read_text().split("\n")[:-1]]
                print(f"Foreground after {stage}: {entries[-1]['name']} ({entries[-1]['pid']}); Turf PID {pid}", flush=True)
                assert not any(entry['pid'] == pid for entry in entries), entries
            run_checks(check_focus)
            print("No Turf activation detected throughout startup, input, and shutdown.")
            # --no-focus also works without an automation endpoint.
            binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/turf"
            plain = subprocess.Popen([str(binary), "--no-focus"])
            try:
                time.sleep(2)
                assert plain.poll() is None
                check_focus(plain.pid, "startup without automation")
            finally:
                plain.terminate()
                plain.wait(timeout=5)
            # Foreground remains the default for interactive automation.
            endpoint = folder / "foreground.sock"
            foreground = subprocess.Popen([str(binary), "--automation-socket", str(endpoint)])
            try:
                for _ in range(100):
                    if endpoint.exists():
                        break
                    time.sleep(0.05)
                assert client.request(endpoint, "info")["background"] is False
                for _ in range(100):
                    entries = [json.loads(line) for line in marker.read_text().split("\n")[:-1]]
                    if any(entry['pid'] == foreground.pid for entry in entries):
                        break
                    time.sleep(0.05)
                assert any(entry['pid'] == foreground.pid for entry in entries), "Default startup did not activate"
                client.request(endpoint, "navigate", {"url": "about:blank"})
                client.request(endpoint, "evaluate", {"expression": "document.body.innerHTML='<button onclick=\"window.clicked=true\">Click</button>'; document.body.style.margin='0'"})
                client.request(endpoint, "click", {"x": 10, "y": 10})
                for _ in range(100):
                    if client.request(endpoint, "evaluate", {"expression": "window.clicked === true"})["value"]:
                        break
                    time.sleep(0.02)
                assert client.request(endpoint, "evaluate", {"expression": "window.clicked === true"})["value"]
                client.request(endpoint, "close")
                assert foreground.wait(timeout=10) == 0
                print("Default interactive automation activated Turf and delivered a native click.")
            finally:
                if foreground.poll() is None:
                    foreground.terminate()
                    foreground.wait(timeout=5)

        finally:
            process.terminate()
            process.wait(timeout=5)
            log.close()


if __name__ == "__main__":
    main()
