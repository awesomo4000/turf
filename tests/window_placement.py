#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Native Windows/Linux deferred display and screen placement integration checks."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid
import threading
import re
import shutil
from automation_macos import client, expect_error


def wait(check, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return last
        except (OSError, RuntimeError) as error:
            last = str(error)
        time.sleep(.05)
    raise AssertionError(f'Condition did not settle: {last}')


class FocusGuard:
    def __enter__(self):
        self.pids = set()
        self.windows = set()
        self.events = set()
        self.stop = threading.Event()
        self.monitor = None
        if os.name == 'nt':
            import ctypes
            from ctypes import wintypes
            user = ctypes.WinDLL('user32')
            user.GetForegroundWindow.restype = wintypes.HWND
            user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
            def observe():
                while not self.stop.wait(.01):
                    pid = wintypes.DWORD()
                    user.GetWindowThreadProcessId(user.GetForegroundWindow(), ctypes.byref(pid))
                    self.pids.add(pid.value)
        elif shutil.which('xprop') and shutil.which('wmctrl'):
            self.monitor = subprocess.Popen(['xprop', '-root', '-spy', '_NET_ACTIVE_WINDOW'], stdout=subprocess.PIPE, text=True)
            def observe():
                for line in self.monitor.stdout:
                    self.events.update(int(v, 16) for v in re.findall(r'0x[0-9a-fA-F]+', line))
        else:
            def observe():
                pass
        self.thread = threading.Thread(target=observe, daemon=True)
        self.thread.start()
        return self

    def check(self, pid):
        time.sleep(.05)
        if self.monitor:
            assert self.monitor.poll() is None
            result = subprocess.run(['wmctrl', '-lp'], capture_output=True, text=True)
            # A bare Xvfb has no WM or _NET_ACTIVE_WINDOW.
            for line in result.stdout.splitlines():
                fields = line.split()
                if len(fields) > 2 and fields[2] == str(pid):
                    self.windows.add(int(fields[0], 16))
            assert not self.windows.intersection(self.events), 'Turf activated during placement'
        assert pid not in self.pids, 'Turf activated during placement'

    def __exit__(self, *args):
        self.stop.set()
        if self.monitor:
            self.monitor.terminate()
            self.monitor.wait(timeout=5)
        self.thread.join(timeout=5)


def main(focus):
    binary = Path(sys.argv[1]).resolve()
    assert sys.platform != 'darwin', 'Use deferred_show_macos.py with TURF_TEST_SCREEN for macOS tests'
    for never_show in (False, True):
        # Windows profile teardown can lag the host, so use the existing retry helper.
        if os.name == 'nt':
            from automation_windows_protocol import test_directory
            directory = test_directory()
        else:
            directory = tempfile.TemporaryDirectory(prefix='turf-placement-', dir='/tmp')
        with directory as name:
            folder = Path(name)
            endpoint = ('\\\\.\\pipe\\turf-placement-' + uuid.uuid4().hex) if os.name == 'nt' else str(folder / 'control.sock')
            env = os.environ.copy()
            env['WEBVIEW2_USER_DATA_FOLDER'] = str(folder / 'profile')
            with (folder / 'host.log').open('w+') as log:
                process = subprocess.Popen([str(binary), '--start-hidden', '--no-focus', '--automation-socket', endpoint], env=env, stdout=log, stderr=log)
                try:
                    def info():
                        assert process.poll() is None, 'Host exited'
                        return client.request(endpoint, 'info')
                    initial = wait(info)
                    print(json.dumps({'engine': initial['engine'], 'window': initial['window'], 'caps': initial['capabilities']}), flush=True)
                    assert initial['capabilities']['deferredShow']
                    assert not initial['window']['visible']
                    focus.check(process.pid)
                    if not never_show:
                        assert initial['capabilities']['windowPosition']
                        screens = client.request(endpoint, 'screens')['screens']
                        print(json.dumps({'screens': screens}), flush=True)
                        assert screens and len({s['id'] for s in screens}) == len(screens)
                        target = next((s for s in screens if s['isPrimary']), screens[0])
                        work = target['workArea']
                        for method, params in [('key', {'key': 'e'}), ('click', {'x': 10, 'y': 10}), ('typeText', {'text': 'e'})]:
                            expect_error(endpoint, method, params, -32004)
                        client.request(endpoint, 'resize', {'width': 400, 'height': 240})
                        for anchor in ('top-left', 'top-right', 'bottom-left', 'bottom-right'):
                            moved = client.request(endpoint, 'move', {'screen': target['id'], 'anchor': anchor, 'x': 24, 'y': 32})
                            assert not moved['visible'], moved
                            assert moved['screen'] == target['id'], moved
                            ex = 24 if anchor.endswith('left') else max(0, work['width'] - moved['frame']['width'] - 24)
                            ey = 32 if anchor.startswith('top') else max(0, work['height'] - moved['frame']['height'] - 32)
                            assert abs(moved['x'] - ex) <= 1 and abs(moved['y'] - ey) <= 1, moved
                        expect_error(endpoint, 'move', {'screen': 'missing'}, -32602)
                        expect_error(endpoint, 'move', {'screen': target['id'], 'x': True}, -32602)
                        expect_error(endpoint, 'move', {'screen': target['id'], 'y': -1}, -32602)
                        expect_error(endpoint, 'move', {'screen': target['id'], 'anchor': 'center'}, -32602)
                        clamped = client.request(endpoint, 'move', {'screen': target['id'], 'x': 1e9, 'y': 1e9})
                        assert clamped['x'] + clamped['frame']['width'] <= work['width'] + 1
                        assert clamped['y'] + clamped['frame']['height'] <= work['height'] + 1
                        positioned = client.request(endpoint, 'move', {'screen': target['id'], 'x': 80, 'y': 100})
                        time.sleep(.3)
                        assert not info()['window']['visible']
                        client.request(endpoint, 'show')
                        wait(lambda: info()['window']['visible'])
                        time.sleep(.5)
                        shown = info()['window']
                        print(json.dumps({'shown': shown, 'positioned': positioned}), flush=True)
                        assert shown['screen'] == positioned['screen']
                        assert shown['frame']['width'] == positioned['frame']['width'] and shown['frame']['height'] == positioned['frame']['height'], (shown, positioned)
                        assert abs(shown['x'] - 80) <= 2 and abs(shown['y'] - 100) <= 2, shown
                        assert not shown['focused'], shown
                        client.request(endpoint, 'show')
                        assert not info()['window']['focused']
                        focus.check(process.pid)
                        moved = client.request(endpoint, 'move', {'screen': target['id'], 'x': 120, 'y': 140})
                        assert abs(moved['x'] - 120) <= 2 and abs(moved['y'] - 140) <= 2, moved
                        wait(lambda: abs(info()['window']['x'] - 120) <= 2 and abs(info()['window']['y'] - 140) <= 2)
                        assert not info()['window']['focused']
                        focus.check(process.pid)
                        wait(lambda: not info()['loading'])
                        result = client.request(endpoint, 'evaluate', {'expression': "document.body.innerHTML='<textarea></textarea>'; document.querySelector('textarea').focus(); 42"})
                        assert result['value'] == 42
                        client.request(endpoint, 'typeText', {'text': 'deferred 🦦'})
                        wait(lambda: client.request(endpoint, 'evaluate', {'expression': "document.querySelector('textarea').value"})['value'] == 'deferred 🦦')
                    focus.check(process.pid)
                    client.request(endpoint, 'close')
                    assert process.wait(timeout=10) == 0
                except BaseException:
                    log.seek(0)
                    print(log.read(), file=sys.stderr)
                    raise
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
    print('PASS: screens, hidden resize/move, all anchors, first show, no-focus, input, and never-shown shutdown')


if __name__ == '__main__':
    with FocusGuard() as focus:
        main(focus)
