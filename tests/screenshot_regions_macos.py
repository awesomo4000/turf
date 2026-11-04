#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Real WKWebView region captures, raster comparisons, validation, and focus checks."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import tempfile

from automation_macos import ROOT, client
from automation_diagnostics_macos import wait

from screenshot_contract import SCENE, contract


@contextmanager
def window(binary, folder):
    endpoint = folder / 'control.sock'
    with (folder / 'host.log').open('w+') as log:
        process = subprocess.Popen([str(binary), '--start-hidden', '--no-focus', '--automation-socket', str(endpoint)], stdout=log, stderr=log)
        try:
            wait(lambda: endpoint.exists() or process.poll() is not None)
            assert process.poll() is None
            screens = client.request(endpoint, 'screens')['screens']
            selected = [s for s in screens if os.environ['TURF_TEST_SCREEN'].casefold() in s['name'].casefold()]
            assert len(selected) == 1
            work = selected[0]['workArea']
            client.request(endpoint, 'resize', {'width':520, 'height':220})
            frame = client.request(endpoint, 'info')['window']['frame']
            client.request(endpoint, 'move', {'screen':selected[0]['id'], 'x':(work['width']-frame['width'])/2,
                           'y':work['height']*5/6-frame['height']/2})
            shown = client.request(endpoint, 'show')
            assert shown['visible'] and not shown['focused']
            wait(lambda: client.request(endpoint, 'evaluate', {'expression':'document.readyState === "complete"'})['value'])
            client.request(endpoint, 'evaluate', {'expression':'document.body.innerHTML=' + json.dumps(SCENE)})
            wait(lambda: client.request(endpoint, 'evaluate', {'expression':'document.querySelector("#frame").contentDocument?.readyState === "complete"'})['value'])
            client.request(endpoint, 'evaluate', {'expression':'new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))'})
            yield endpoint, process.pid
            client.request(endpoint, 'close')
            assert process.wait(timeout=10) == 0
        except BaseException:
            log.seek(0)
            print(log.read())
            raise
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-binary', type=Path)
    args = parser.parse_args()
    assert os.environ.get('TURF_TEST_SCREEN', '').strip(), 'Set TURF_TEST_SCREEN'
    with tempfile.TemporaryDirectory(prefix='turf-regions-', dir='/tmp') as directory:
        folder = Path(directory)
        guard_binary = folder/'focus-guard'
        subprocess.run(['clang','-fobjc-arc','-framework','Cocoa',str(ROOT/'tests/automation_focus_guard.m'),'-o',str(guard_binary)],check=True)
        focus = folder/'focus.jsonl'
        with focus.open('w') as output:
            guard = subprocess.Popen([str(guard_binary)],stdout=output)
            pids = []
            try:
                wait(lambda: focus.stat().st_size > 0)
                baseline = None
                if args.baseline_binary:
                    with window(args.baseline_binary,folder) as (endpoint,pid):
                        pids.append(pid)
                        baseline = client.request(endpoint,'screenshot')
                with window(ROOT/'zig-out/bin/turf',folder) as (endpoint,pid):
                    pids.append(pid)
                    contract(endpoint,folder,baseline)
                rows = [json.loads(line) for line in focus.read_text().splitlines()]
                assert not any(row['pid'] in pids for row in rows), rows
                print('PASS: selected display placement and no focus activation')
            finally:
                guard.terminate()
                guard.wait(timeout=5)


if __name__ == '__main__':
    main()
