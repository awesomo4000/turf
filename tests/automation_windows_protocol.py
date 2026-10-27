#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Real Turf named-pipe tests. No Playwright and no debugging port."""
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import automation_macos as suite


@contextmanager
def test_directory():
    directory = tempfile.mkdtemp(prefix='turf-pipe-test-')
    try:
        yield directory
    finally:
        # WebView2's browser process may flush its profile after the host exits.
        for attempt in range(100):
            try:
                shutil.rmtree(directory)
                break
            except FileNotFoundError:
                break
            except OSError:
                if attempt == 99:
                    raise
                time.sleep(.1)


def main():
    binary = Path(sys.argv[1]).resolve()
    client = suite.client
    user = ctypes.WinDLL('user32', use_last_error=True)
    user.GetForegroundWindow.restype = wintypes.HWND
    user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    focus_pids = set()
    stop = threading.Event()
    def observe():
        while not stop.wait(.01):
            pid = wintypes.DWORD()
            user.GetWindowThreadProcessId(user.GetForegroundWindow(), ctypes.byref(pid))
            focus_pids.add(pid.value)
    observer = threading.Thread(target=observe)
    observer.start()
    try:
        for background in (True, False):
            with test_directory() as directory:
                folder = Path(directory)
                fixture = folder / 'fixture.html'
                fixture.write_text('<!doctype html><title>Pipe fixture</title><h1>Hello</h1><select id="choices" size="3"><option>One</option><option>Two</option><option>Three</option></select><button id="button">Click</button><textarea id="editor" rows="8">First line\nSecond line\nThird line</textarea>')
                pipe = '\\\\.\\pipe\\turf-test-' + uuid.uuid4().hex
                env = os.environ.copy()
                env.pop('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', None)
                env['WEBVIEW2_USER_DATA_FOLDER'] = str(folder / 'profile')
                with (folder/'turf.log').open('w+') as log:
                    process = subprocess.Popen([str(binary), '--automation-socket', pipe,
                        *(['--no-focus'] if background else []), str(fixture)], env=env, stdout=log, stderr=log)
                    try:
                        for _ in range(200):
                            if process.poll() is not None:
                                raise AssertionError(f'Turf exited: {process.returncode}')
                            try:
                                info = client.request(pipe, 'info')
                                if not info['loading']:
                                    break
                            except (OSError, RuntimeError):
                                pass
                            time.sleep(.1)
                        else:
                            raise AssertionError('Pipe/WebView2 did not become ready')
                        assert info['engine'] == 'WebView2' and info['background'] is background
                        assert info['title'] == 'Pipe fixture', info
                        assert client.request(pipe, 'navigate', {'url': fixture.as_uri()})['url'] == fixture.as_uri()
                        def evaluate(expression):
                            return client.request(pipe, 'evaluate', {'expression': expression})
                        assert evaluate('new Promise(r=>setTimeout(()=>r(42),30))')['value'] == 42
                        assert evaluate('undefined') == {'type': 'undefined'}
                        assert evaluate('null') == {'type': 'null', 'value': None}
                        suite.expect_error(pipe, 'evaluate', {'expression': 'throw new Error("test")'}, -32002)
                        suite.expect_error(pipe, 'evaluate', {'expression': '(()=>{let a={};a.a=a;return a})()'}, -32002)
                        suite.expect_error(pipe, 'resize', {'width': True, 'height': 100}, -32602)
                        suite.expect_error(pipe, 'navigate', {'url': 'relative.html'}, -32602)
                        suite.expect_error(pipe, 'unknown', {}, -32601)
                        for raw in (b'not json\n', b'[]\n', b'{"jsonrpc":"2.0","id":1,"method":"info","params":null}\n'):
                            assert 'error' in json.loads(client._pipe_exchange(pipe, raw))
                        response = json.loads(client._pipe_exchange(pipe, json.dumps({'jsonrpc': '2.0', 'id': 'otter-id', 'method': 'info'}).encode() + b'\n'))
                        assert response['id'] == 'otter-id'
                        oversized = client._pipe_exchange(pipe, b'x' * (1024 * 1024 + 1) + b'\n')
                        assert json.loads(oversized)['error']['code'] == -32600
                        duplicate = subprocess.Popen([str(binary), '--automation-socket', pipe], env=env, stdout=log, stderr=log)
                        assert duplicate.wait(timeout=10) != 0
                        suite.feature_checks(pipe, folder, engine='WebView2')
                        assert client.request(pipe, 'resize', {'width': 420, 'height': 320}) == {'width': 420, 'height': 320}
                        png = client.request(pipe, 'screenshot')
                        assert base64.b64decode(png['data'], validate=True).startswith(b'\x89PNG\r\n\x1a\n')
                        assert png['width'] > 0 and png['height'] > 0
                        if background:
                            assert process.pid not in focus_pids, 'Background automation activated Turf'
                            with ThreadPoolExecutor() as pool:
                                pending = pool.submit(suite.expect_error, pipe, 'evaluate', {'expression': 'new Promise(r=>setTimeout(()=>r(99),31000))'}, -32001)
                                time.sleep(.1)
                                started = time.monotonic()
                                assert client.request(pipe, 'info')['engine'] == 'WebView2'
                                assert time.monotonic() - started < 2
                                pending.result(timeout=35)
                                time.sleep(1.5)
                                assert evaluate('42')['value'] == 42
                        with ThreadPoolExecutor() as pool:
                            pending = pool.submit(evaluate, 'new Promise(()=>{})')
                            time.sleep(.1)
                            assert client.request(pipe, 'close') == {'closing': True}
                            assert process.wait(timeout=10) == 0
                            if background:
                                assert process.pid not in focus_pids, 'Background shutdown activated Turf'
                            try:
                                pending.result(timeout=5)
                            except (OSError, RuntimeError):
                                pass
                            else:
                                raise AssertionError('Pending operation survived window close')
                        print(f'Passed named-pipe protocol, native input, grab, PNG, duplicate-endpoint, and close checks; background={background}', flush=True)
                    except Exception:
                        log.flush(); log.seek(0); print(log.read(), file=sys.stderr)
                        raise
                    finally:
                        if process.poll() is None:
                            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True)
                            process.wait(timeout=10)
    finally:
        stop.set(); observer.join()


if __name__ == '__main__':
    main()
