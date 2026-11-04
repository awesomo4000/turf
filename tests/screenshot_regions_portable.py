#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Regional screenshots on Linux/Xvfb or a Windows desktop session."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
from automation_macos import ROOT, client
from automation_diagnostics_macos import wait
from screenshot_contract import SCENE, contract


@contextmanager
def window(binary, folder):
    endpoint = r'\\.\pipe\turf-regions-' + uuid.uuid4().hex if os.name == 'nt' else str(folder/'control.sock')
    env = os.environ.copy()
    env['WEBVIEW2_USER_DATA_FOLDER'] = str(folder/'profile')
    fixture = folder/'scene.html'
    fixture.write_text('<!doctype html><html><body>'+SCENE+'</body></html>', encoding='utf-8')
    with (folder/'host.log').open('w+') as log:
        process = subprocess.Popen([str(binary), '--start-hidden', '--no-focus', '--automation-socket', endpoint, str(fixture)], env=env, stdout=log, stderr=log)
        try:
            def ready():
                assert process.poll() is None, 'Turf exited during startup'
                try: return client.request(endpoint, 'info')
                except (OSError, RuntimeError): return False
            wait(ready, timeout=20)
            client.request(endpoint, 'resize', {'width':520,'height':220})
            shown = client.request(endpoint, 'show')
            assert shown['visible'] and not shown['focused'], shown
            wait(lambda: client.request(endpoint,'evaluate',{'expression':'document.readyState === "complete" && !!document.querySelector("#target")'})['value'])
            wait(lambda: client.request(endpoint,'evaluate',{'expression':'document.querySelector("#frame").contentDocument?.readyState === "complete"'})['value'])
            client.request(endpoint,'evaluate',{'expression':'new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))'})
            yield endpoint
            client.request(endpoint,'close')
            assert process.wait(timeout=10) == 0
        except BaseException:
            log.seek(0); print(log.read())
            raise
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', nargs='?', type=Path, default=ROOT/'zig-out/bin/turf')
    parser.add_argument('--baseline-binary', type=Path)
    args = parser.parse_args()
    # Windows test_directory retries cleanup while WebView2 flushes its profile.
    if os.name == 'nt':
        from automation_windows_protocol import test_directory
        directory = test_directory()
    else:
        directory = tempfile.TemporaryDirectory(prefix='turf-regions-',dir='/tmp')
    with directory as name:
        folder = Path(name)
        baseline = None
        if args.baseline_binary:
            old = folder/'baseline'; old.mkdir(mode=0o700)
            with window(args.baseline_binary.resolve(),old) as endpoint:
                baseline = client.request(endpoint,'screenshot')
                baseline.pop('region',None)
        new = folder/'current'; new.mkdir(mode=0o700)
        with window(args.binary.resolve(),new) as endpoint:
            contract(endpoint,new,baseline)


if __name__ == '__main__': main()
