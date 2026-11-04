#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""macOS agent-diagnostics contract checks; explicitly selected display, no focus."""
import json
import functools
import http.server
import threading
import os
from pathlib import Path
import subprocess
import tempfile
import time
from automation_macos import ROOT, client, feature_checks
from diagnostics_contract import run_contract


def wait(check, timeout=10):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = check()
        if last:
            return last
        time.sleep(.03)
    raise AssertionError(f'Condition timed out; last result: {last!r}')


def run(binary, folder, focus_log, fixture_url):
    endpoint = folder / 'control.sock'
    with (folder / 'host.log').open('w+') as log:
        process = subprocess.Popen([str(binary), '--start-hidden', '--no-focus', '--automation-socket', str(endpoint)], stdout=log, stderr=log)
        try:
            wait(lambda: endpoint.exists() or process.poll() is not None)
            assert process.poll() is None
            def request(method, params=None):
                return client.request(endpoint, method, params)
            def evaluate(source):
                return request('evaluate', {'expression': source})
            info = request('info')
            host_pid = info['pid']
            assert info['capabilities']['structuredErrors'] and info['capabilities']['diagnostics']
            screens = request('screens')['screens']
            matches = [s for s in screens if os.environ['TURF_TEST_SCREEN'].casefold() in s['name'].casefold()]
            assert len(matches) == 1, 'Display selector must match exactly one display'
            target = matches[0]
            request('resize', {'width': 520, 'height': 220})
            frame = request('info')['window']['frame']
            work = target['workArea']
            request('move', {'screen': target['id'], 'x': (work['width']-frame['width'])/2, 'y': work['height']*5/6-frame['height']/2})
            request('show')
            wait(lambda: evaluate('document.visibilityState')['value'] == 'visible')

            run_contract(endpoint, folder, fixture_url)
            fixture = '<h1 id="heading" style="margin:0;font-size:18px">Hello</h1><select id="choices" size="3"><option>One</option><option>Two</option><option>Three</option></select><button id="button">Click</button><textarea id="editor" rows="4">First line\nSecond line\nThird line</textarea>'
            evaluate('document.body.innerHTML=' + json.dumps(fixture))
            feature_checks(endpoint, folder, check_position=False)
            png = request('screenshot')
            import base64, struct
            data = base64.b64decode(png['data'], validate=True)
            assert data.startswith(b'\x89PNG\r\n\x1a\n')
            assert struct.unpack('>II', data[16:24]) == (png['width'], png['height'])
            print('PASS: native keys/text/clicks, 33 MiB grab, failure cleanup, screenshot regression', flush=True)
            # Timeout must not imply cancellation or cause an automatic retry.
            try: evaluate('new Promise(resolve=>setTimeout(()=>{window.late=(window.late||0)+1;resolve(1)},31000))')
            except RuntimeError as error:
                timeout = json.loads(str(error))
                assert timeout['code'] == -32001 and timeout['data']['kind'] == 'timeout' and timeout['data']['mayStillRun'] is True
            else: raise AssertionError('Expected timeout')
            wait(lambda: evaluate('window.late === 1')['value'], timeout=5)
            assert evaluate('42')['value'] == 42
            request('close')
            assert process.wait(timeout=10) == 0
            time.sleep(.1)
            events = [json.loads(line) for line in focus_log.read_text().splitlines()]
            assert not any(e['pid']==host_pid for e in events), events
            print('PASS: timeout, late completion, recovery, shutdown, no focus activation', flush=True)
        except BaseException:
            log.seek(0); print(log.read())
            try: print(json.dumps(client.request(endpoint, 'diagnostics'), indent=2))
            except Exception: pass
            raise
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=10)


def main():
    if not os.environ.get('TURF_TEST_SCREEN','').strip():
        raise SystemExit('Set TURF_TEST_SCREEN to a unique display-name substring')
    with tempfile.TemporaryDirectory(prefix='turf-diagnostics-',dir='/tmp') as directory:
        folder=Path(directory)
        guard=folder/'focus-guard'
        subprocess.run(['clang','-fobjc-arc','-framework','Cocoa',str(ROOT/'tests/automation_focus_guard.m'),'-o',str(guard)],env={**os.environ,'TMPDIR':directory},check=True)
        path=folder/'focus.jsonl'
        with path.open('w') as output:
            observer=subprocess.Popen([str(guard)],stdout=output)
            try:
                wait(lambda:path.stat().st_size > 0)
                class Handler(http.server.SimpleHTTPRequestHandler):
                    def log_message(self, *args): pass
                handler = functools.partial(Handler, directory=str(ROOT/'tests/fixtures/automation'))
                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    run(Path(os.environ.get('TURF_TEST_BINARY', ROOT/'zig-out/bin/turf')).resolve(), folder, path, f'http://127.0.0.1:{server.server_port}/diagnostics.html')
                finally:
                    server.shutdown(); server.server_close(); thread.join(timeout=5)
            finally:
                observer.terminate();observer.wait(timeout=5)

if __name__=='__main__': main()
