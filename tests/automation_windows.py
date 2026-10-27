#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Smoke-test the actual Windows Turf WebView2 through its opt-in CDP endpoint.

Requires: pip install playwright. No separate browser download is needed.
"""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from playwright.sync_api import sync_playwright


def main():
    if sys.platform != 'win32':
        raise SystemExit('Run this test on Windows')
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/turf.exe').resolve()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='turf-webview2-') as directory:
        folder = Path(directory)
        env = os.environ.copy()
        env['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'] = f'--remote-debugging-port={port}'
        env['WEBVIEW2_USER_DATA_FOLDER'] = str(folder / 'profile')
        with (folder / 'turf.log').open('w+') as log:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            try:
                with sync_playwright() as playwright:
                    browser = None
                    for _ in range(60):
                        if process.poll() is not None:
                            raise RuntimeError(f'Turf exited with {process.returncode}')
                        try:
                            browser = playwright.chromium.connect_over_cdp(f'http://127.0.0.1:{port}', timeout=1000)
                            break
                        except Exception:
                            time.sleep(0.5)
                    if browser is None:
                        raise RuntimeError('WebView2 CDP did not become available')
                    context = browser.contexts[0]
                    for _ in range(100):
                        if context.pages:
                            break
                        time.sleep(0.1)
                    page = context.pages[0]
                    page.wait_for_function('typeof window.turf === "object"')
                    # The demo starts the optional native message pump; the CLI does not.
                    if '--bridge' in sys.argv:
                        page.evaluate('''() => {
                            window.receivedPong = false;
                            turf.onMessage('pong', () => window.receivedPong = true);
                            turf.send({type: 'ping'});
                        }''')
                        page.wait_for_function('window.receivedPong')
                        print('Passed native bridge ping/pong.', flush=True)
                    page.evaluate('''() => {
                        document.body.innerHTML = '<button id="test">Click</button><input id="text">';
                        document.querySelector('#test').onclick = event => window.trustedClick = event.isTrusted;
                    }''')
                    page.locator('#test').click()
                    assert page.evaluate('window.trustedClick') is True
                    page.locator('#text').fill('Turf WebView2 test')
                    assert page.locator('#text').input_value() == 'Turf WebView2 test'
                    png = page.screenshot()
                    assert png.startswith(b'\x89PNG\r\n\x1a\n') and len(png) > 1000
                    print(f'Passed real WebView2 CDP input, DOM, and PNG checks. PID {process.pid}', flush=True)
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True)
                    process.wait(timeout=10)


if __name__ == '__main__':
    main()
