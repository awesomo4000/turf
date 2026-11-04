#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Check that a real embedder regains control and frees its own allocations."""
import json
import os
from pathlib import Path
import subprocess
import socket
import tempfile
import time

from automation_macos import ROOT, client


def wait_endpoint(endpoint, process):
    deadline = time.monotonic() + 15
    while True:
        assert process.poll() is None, 'embedder exited before startup'
        assert time.monotonic() < deadline, 'embedder startup timed out'
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(.25)
                connection.connect(str(endpoint))
                connection.sendall(b'{"jsonrpc":"2.0","id":1,"method":"info"}\n')
                with connection.makefile('rb') as stream:
                    line = stream.readline(65536)
                if line:
                    assert json.loads(line)['result']['engine'] == 'WKWebView'
                    return
        except (FileNotFoundError, ConnectionRefusedError, ConnectionResetError, BrokenPipeError, TimeoutError):
            pass  # Fixture intentionally stops/restarts its endpoint before run().
        time.sleep(.02)


def main():
    screen_name = os.environ.get('TURF_TEST_SCREEN', '').strip()
    assert screen_name, 'Set TURF_TEST_SCREEN before running GUI tests'
    binary = ROOT / 'zig-out/bin/embedder-lifecycle'
    with tempfile.TemporaryDirectory(prefix='turf-embedder-', dir='/tmp') as directory:
        folder = Path(directory)
        observer = folder / 'focus-guard'
        subprocess.run(['clang', '-fobjc-arc', '-framework', 'Cocoa',
                        str(ROOT / 'tests/automation_focus_guard.m'), '-o', str(observer)], check=True)
        with (folder / 'focus.jsonl').open('w') as focus_log:
            guard = subprocess.Popen([str(observer)], stdout=focus_log)
            try:
                deadline = time.monotonic() + 5
                while not (folder / 'focus.jsonl').stat().st_size:
                    assert guard.poll() is None and time.monotonic() < deadline
                    time.sleep(.02)
                for visible in (False, True):
                    endpoint = folder / 'control.sock'
                    with (folder / 'embedder.log').open('w+') as log:
                        process = subprocess.Popen([str(binary), str(endpoint)], stdout=log, stderr=log)
                        try:
                            wait_endpoint(endpoint, process)
                            info = client.request(endpoint, 'info')
                            assert not info['window']['visible']
                            if visible:
                                screens = client.request(endpoint, 'screens')['screens']
                                matches = [s for s in screens if screen_name.casefold() in s['name'].casefold()]
                                assert len(matches) == 1
                                screen = matches[0]
                                work = screen['workArea']
                                frame = info['window']['frame']
                                client.request(endpoint, 'move', {
                                    'screen': screen['id'],
                                    'x': (work['width'] - frame['width']) / 2,
                                    'y': work['height'] * 5 / 6 - frame['height'] / 2,
                                })
                                shown = client.request(endpoint, 'show')
                                assert shown['visible'] and not shown['focused']
                            deadline = time.monotonic() + 10
                            while not client.request(endpoint, 'evaluate', {'expression': "document.title === 'Embedder lifecycle' && document.readyState === 'complete' && typeof turf !== 'undefined'"})['value']:
                                assert time.monotonic() < deadline, 'fixture page did not load'
                                time.sleep(.02)
                            # Exercise the worker with real native replies before teardown.
                            client.request(endpoint, 'evaluate', {'expression': """
                                window.receivedPongs = 0;
                                const originalHandler = turf._handleNativeMessage;
                                turf._handleNativeMessage = function(message) {
                                    if (message.type === 'pong') receivedPongs++;
                                    return originalHandler.call(this, message);
                                };
                                for (let i = 0; i < 200; i++)
                                    turf.send({type:'ping'});
                            """})
                            deadline = time.monotonic() + 10
                            count_expression = 'receivedPongs'
                            while client.request(endpoint, 'evaluate', {'expression': count_expression})['value'] != 200:
                                assert time.monotonic() < deadline, 'native queue failed to drain'
                                time.sleep(.02)
                            # Close while the page is still producing native messages.
                            client.request(endpoint, 'evaluate', {'expression': "setInterval(() => turf.send({type:'ping'}), 1); null"})
                            client.request(endpoint, 'close')
                            assert process.wait(timeout=10) == 0
                            log.seek(0)
                            output = log.read()
                            for marker in ('RUN_RETURNED', 'WINDOW_DEINITIALIZED', 'QUEUE_DEINITIALIZED'):
                                assert marker in output, f'{marker} missing; process exited without cleanup:\n{output}'
                            assert not endpoint.exists(), 'socket survived teardown'
                            rows = [json.loads(line) for line in (folder / 'focus.jsonl').read_text().splitlines()]
                            assert not any(row['pid'] == info['pid'] for row in rows), rows
                            print(f'PASS: embedder returned, freed window/queue, removed socket; visible={visible}')
                        finally:
                            if process.poll() is None:
                                process.kill()
                                process.wait()
            finally:
                guard.terminate()
                guard.wait(timeout=5)


if __name__ == '__main__':
    main()
