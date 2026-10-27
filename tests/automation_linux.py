#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Real WebKitGTK socket tests. X11 tools only observe focus, never deliver input."""
import os
import json
import socket
import tempfile
from pathlib import Path
import re
import subprocess
import threading
import time
import automation_macos as suite


def lifecycle_checks():
    client = suite.client
    binary = Path(suite.sys.argv[1]).resolve() if len(suite.sys.argv) > 1 else suite.ROOT / 'zig-out/bin/turf'
    with tempfile.TemporaryDirectory(prefix='turf-linux-protocol-', dir='/tmp') as directory:
        folder = Path(directory)
        path = folder / 'control.sock'
        process = subprocess.Popen([str(binary), '--no-focus', '--automation-socket', str(path)])
        try:
            for _ in range(200):
                if path.exists():
                    break
                time.sleep(0.05)
            for method, params in [('evaluate', {'expression': '42\0bad'}), ('typeText', {'text': 'hi\0bad'})]:
                suite.expect_error(path, method, params, -32602)
            for request, code in [
                ([], -32600), ({'jsonrpc': '2.0', 'id': None, 'method': 'close'}, -32600),
                ({'jsonrpc': '2.0', 'id': 9, 'method': 'close', 'params': None}, -32602),
                ({'jsonrpc': '2.0', 'id': 9, 'method': 'close\0junk'}, -32600),
            ]:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(5)
                    connection.connect(str(path))
                    connection.sendall(json.dumps(request).encode() + b'\n')
                    with connection.makefile('rb') as stream:
                        assert json.loads(stream.readline())['error']['code'] == code
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(path))
                connection.sendall(b'x' * (1024 * 1024 + 1) + b'\n')
                with connection.makefile('rb') as stream:
                    assert json.loads(stream.readline())['error']['code'] == -32600
            assert client.request(path, 'info')['engine'] == 'WebKitGTK'
            # One client waiting on JS must not block another client's info/close.
            with socket.socket(socket.AF_UNIX) as pending:
                pending.connect(str(path))
                pending.sendall(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'evaluate',
                    'params': {'expression': 'new Promise(() => {})'}}).encode() + b'\n')
                time.sleep(0.1)
                started = time.monotonic()
                assert client.request(path, 'info')['engine'] == 'WebKitGTK'
                assert time.monotonic() - started < 2
                assert client.request(path, 'close') == {'closing': True}
                assert process.wait(timeout=5) == 0
            assert not path.exists()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        # All rejection targets are disposable; existing files must survive.
        public = folder / 'public'
        public.mkdir(mode=0o755)
        result = subprocess.run([str(binary), '--no-focus', '--automation-socket', str(public/'control.sock')], capture_output=True, timeout=5)
        assert result.returncode != 0 and not (public/'control.sock').exists()
        link = folder / 'link'
        link.symlink_to(public, target_is_directory=True)
        result = subprocess.run([str(binary), '--no-focus', '--automation-socket', str(link/'control.sock')], capture_output=True, timeout=5)
        assert result.returncode != 0 and not (public/'control.sock').exists()
    print('Passed Linux protocol limits, concurrent clients, cancellation, and safe-path checks.')


def main():
    assert os.environ.get('DISPLAY'), 'Run in an X11 desktop session with DISPLAY set'
    events = []
    monitor = subprocess.Popen(['xprop', '-root', '-spy', '_NET_ACTIVE_WINDOW'], stdout=subprocess.PIPE, text=True)
    def record():
        for line in monitor.stdout:
            events.extend(int(value, 16) for value in re.findall(r'0x[0-9a-fA-F]+', line))
    thread = threading.Thread(target=record, daemon=True)
    thread.start()
    windows = set()
    def check_focus(pid, stage):
        for _ in range(100):
            for row in subprocess.check_output(['wmctrl', '-lp'], text=True).splitlines():
                fields = row.split()
                if len(fields) >= 3 and fields[2] == str(pid):
                    windows.add(int(fields[0], 16))
            if windows:
                break
            time.sleep(0.05)
        time.sleep(0.05)
        assert monitor.poll() is None, 'Focus monitor exited'
        assert windows, 'No Turf X11 window found'
        assert not windows.intersection(events), f'Turf stole focus during {stage}'
        print(f'No Turf focus activation during {stage}', flush=True)
    try:
        for _ in range(100):
            if events:
                break
            time.sleep(0.01)
        assert events, 'Focus monitor did not report the initial foreground window'
        suite.run_checks(check_focus, engine='WebKitGTK')
        lifecycle_checks()
        suite.run_checks(lambda pid, stage: print(f"Foreground check: {stage}", flush=True), engine="WebKitGTK", background=False)
    finally:
        monitor.terminate()
        monitor.wait(timeout=5)
        thread.join(timeout=1)


if __name__ == '__main__':
    main()
