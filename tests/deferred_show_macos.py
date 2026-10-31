#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Verify hidden startup and first show on the Dell, centered in its lower third."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from automation_macos import ROOT, client, expect_error


def main():
    binary = ROOT / 'zig-out/bin/turf'
    with tempfile.TemporaryDirectory(prefix='turf-deferred-', dir='/tmp') as directory:
        folder = Path(directory)
        observer = folder / 'focus-guard'
        subprocess.run(['clang', '-fobjc-arc', '-framework', 'Cocoa',
                        str(ROOT / 'tests/automation_focus_guard.m'), '-o', str(observer)],
                       env={**os.environ, 'TMPDIR': directory}, check=True)
        with (folder / 'focus.jsonl').open('w') as focus_log:
            guard = subprocess.Popen([str(observer)], stdout=focus_log)
            process = None
            try:
                deadline = time.monotonic() + 5
                while not (folder / 'focus.jsonl').stat().st_size:
                    assert guard.poll() is None and time.monotonic() < deadline
                    time.sleep(.02)
                endpoint = folder / 'control.sock'
                process = subprocess.Popen([str(binary), '--no-focus', '--start-hidden',
                                            '--automation-socket', str(endpoint)])
                deadline = time.monotonic() + 15
                while not endpoint.exists():
                    assert process.poll() is None and time.monotonic() < deadline
                    time.sleep(.02)
                def info():
                    return client.request(endpoint, 'info')
                assert info()['capabilities']['deferredShow']
                assert not info()['window']['visible']
                for method, params in [('key', {'key': 'e'}), ('click', {'x': 10, 'y': 10}), ('typeText', {'text': 'e'})]:
                    expect_error(endpoint, method, params, -32004)
                screens = client.request(endpoint, 'screens')['screens']
                dell = next((s for s in screens if 'dell' in s['name'].lower()), None)
                assert dell is not None, 'Dell unavailable; refusing to show on another screen'
                work = dell['workArea']
                client.request(endpoint, 'resize', {'width': 520, 'height': min(220, int(work['height'] / 3) - 50)})
                frame = info()['window']['frame']
                x = (work['width'] - frame['width']) / 2
                y = work['height'] * 5 / 6 - frame['height'] / 2
                placed = client.request(endpoint, 'move', {'screen': dell['id'], 'x': x, 'y': y})
                assert placed['screen'] == dell['id'] and not placed['visible']
                assert abs(placed['x'] - x) <= 1 and abs(placed['y'] - y) <= 1
                for _ in range(10):
                    assert not info()['window']['visible']
                    time.sleep(.1)
                # Hidden-page setup must not require a rendering callback.
                client.request(endpoint, 'evaluate', {'expression': "document.body.innerHTML='<button id=button>Deferred show</button><textarea id=editor></textarea>'; window.framesSeen=0; requestAnimationFrame(function tick(){framesSeen++; requestAnimationFrame(tick)})"})
                shown = client.request(endpoint, 'show')
                assert shown['visible'] and not shown['focused']
                assert shown['screen'] == dell['id'] and shown['frame'] == placed['frame']
                assert client.request(endpoint, 'show') == shown, 'show must be idempotent'
                deadline = time.monotonic() + 5
                while not client.request(endpoint, 'evaluate', {'expression': 'framesSeen > 0 && document.visibilityState === "visible"'})['value']:
                    assert time.monotonic() < deadline
                    time.sleep(.05)
                client.request(endpoint, 'evaluate', {'expression': "document.querySelector('#editor').focus()"})
                client.request(endpoint, 'key', {'key': 'e'})
                deadline = time.monotonic() + 5
                while client.request(endpoint, 'evaluate', {'expression': "document.querySelector('#editor').value"})['value'] != 'e':
                    assert time.monotonic() < deadline
                    time.sleep(.05)
                client.request(endpoint, 'close')
                assert process.wait(timeout=10) == 0
                time.sleep(.1)
                assert guard.poll() is None
                entries = [json.loads(line) for line in (folder / 'focus.jsonl').read_text().splitlines()]
                assert not any(row['pid'] == process.pid for row in entries), entries
                # A client can also close a deferred window without ever showing it.
                hidden_endpoint = folder / 'never-shown.sock'
                process = subprocess.Popen([str(binary), '--no-focus', '--start-hidden',
                                            '--automation-socket', str(hidden_endpoint)])
                deadline = time.monotonic() + 15
                while not hidden_endpoint.exists():
                    assert process.poll() is None and time.monotonic() < deadline
                    time.sleep(.02)
                assert not client.request(hidden_endpoint, 'info')['window']['visible']
                client.request(hidden_endpoint, 'close')
                assert process.wait(timeout=10) == 0
                entries = [json.loads(line) for line in (folder / 'focus.jsonl').read_text().splitlines()]
                assert not any(row['pid'] == process.pid for row in entries), entries
                print(f"PASS: hidden startup, placement before show on {dell['name']} lower-third center, rendering, input, and focus preservation")
            finally:
                if process and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                guard.terminate()
                guard.wait(timeout=5)


if __name__ == '__main__':
    main()
