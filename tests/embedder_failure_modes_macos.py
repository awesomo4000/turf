#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Failure-mode regressions using hidden, real macOS embedder windows."""
from contextlib import contextmanager
import json
import re
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import time

from automation_macos import ROOT, client
from embedder_lifecycle_macos import wait_endpoint


@contextmanager
def host(rounds=1, extra=()):
    with tempfile.TemporaryDirectory(prefix='turf-failure-modes-', dir='/tmp') as directory:
        folder = Path(directory)
        endpoint = folder / 'control.sock'
        with (folder / 'host.log').open('w+') as log:
            process = subprocess.Popen([str(ROOT / 'zig-out/bin/embedder-lifecycle'), str(endpoint), str(rounds), *map(str, extra)], stdout=log, stderr=log)
            try:
                yield folder, endpoint, process, log
            except BaseException:
                log.seek(0)
                print(log.read())
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


def ready(endpoint, process):
    wait_endpoint(endpoint, process)
    deadline = time.monotonic() + 10
    while True:
        info = client.request(endpoint, 'info')
        assert not info['window']['visible']
        assert info['window']['frame']['x'] == 12 and info['window']['frame']['y'] == 34
        if client.request(endpoint, 'evaluate', {'expression': "document.title === 'Embedder lifecycle' && document.readyState === 'complete' && typeof turf !== 'undefined'"})['value']:
            return info
        assert time.monotonic() < deadline
        time.sleep(.02)


def finished(process, log, rounds=1):
    assert process.wait(timeout=10) == 0
    log.seek(0)
    output = log.read()
    assert output.count('QUEUE_DEINITIALIZED') == rounds, output
    assert output.count('WINDOW_DEINITIALIZED') == rounds, output
    assert output.count('RUN_RETURNED') == rounds, output


def repeated_lifecycle():
    rounds = 12
    with host(rounds) as (folder, base, process, log):
        for index in range(rounds):
            endpoint = Path(f'{base}.{index}')
            ready(endpoint, process)
            client.request(endpoint, 'evaluate', {'expression': f"window.roundMarker = {index}; setInterval(() => turf.send({{type:'ping'}}), 1); null"})
            client.request(endpoint, 'close')
        finished(process, log, rounds)
        assert not list(folder.glob('control.sock*'))
        log.seek(0)
        samples = [tuple(map(int, row)) for row in re.findall(r'RESOURCES windows=(\d+) threads=(\d+) fds=(\d+)', log.read())]
        assert len(samples) == rounds, samples
        # Warm-up can create persistent WebKit/AppKit helpers. Detect per-cycle
        # accumulation while allowing a small number of retiring worker threads.
        for position, allowance in [(0, 1), (1, 6), (2, 6)]:
            assert max(row[position] for row in samples[4:]) <= max(row[position] for row in samples[:4]) + allowance, samples
        print('Resource samples:', samples)
    print('PASS: 12 window lifecycles in one process with active messages and checked Zig allocations')





def command(base, text):
    path = Path(f'{base}.command')
    temporary = path.with_suffix('.tmp')
    temporary.write_text(text)
    temporary.replace(path)
    deadline = time.monotonic() + 5
    while path.exists():
        assert time.monotonic() < deadline, f'Host did not consume {text!r}'
        time.sleep(.01)


def raw_request(endpoint, method, params=None, size=None):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(5)
    if size:
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, size)
    connection.connect(str(endpoint))
    data = json.dumps({'jsonrpc':'2.0', 'id':1, 'method':method, 'params':params or {}}).encode() + b'\n'
    connection.sendall(data)
    return connection


@contextmanager
def slow_server():
    started = threading.Event()
    release = threading.Event()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            started.set()
            release.wait(10)
            self.send_response(200)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            try:
                self.wfile.write(b'<!doctype html><title>slow page</title>')
            except (BrokenPipeError, ConnectionResetError):
                pass
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/', started, release
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join()


def shutdown_pending():
    for operation in ('evaluate', 'navigate', 'diagnostics', 'large-response'):
        with slow_server() as (url, started, release), host(2) as (folder, base, process, log):
            endpoint = Path(f'{base}.0')
            ready(endpoint, process)
            if operation == 'navigate':
                connection = raw_request(endpoint, 'navigate', {'url':url})
                assert started.wait(5), 'navigation never reached server'
            elif operation == 'large-response':
                connection = raw_request(endpoint, 'evaluate', {'expression': "'x'.repeat(16 * 1024 * 1024)"}, size=4096)
                assert connection.recv(1, socket.MSG_PEEK), 'response never started'
            elif operation == 'diagnostics':
                client.request(endpoint, 'diagnostics', {'action':'start'})
                connection = raw_request(endpoint, 'evaluate', {'expression': "for(let i=0;i<1000;i++) console.log('shutdown',i); fetch(" + json.dumps(url) + ")"})
                assert started.wait(5), 'diagnostic/evaluation work never started'
            else:
                connection = raw_request(endpoint, 'evaluate', {'expression': 'fetch(' + json.dumps(url) + ')'})
                assert started.wait(5), 'evaluation never started'
            try:
                # This host control does not depend on the busy automation server.
                command(base, 'close')
                replacement = Path(f'{base}.1')
                ready(replacement, process)
                release.set()
                # Let late callbacks run while a replacement window is active.
                for _ in range(5):
                    assert client.request(replacement, 'evaluate', {'expression': 'document.title'})['value'] == 'Embedder lifecycle'
                    time.sleep(.05)
                client.request(replacement, 'close')
                finished(process, log, 2)
                assert not endpoint.exists() and not replacement.exists()
            finally:
                connection.close()
        print(f'PASS: native shutdown with {operation} pending')


def disconnects():
    with slow_server() as (url, started, release), host() as (folder, endpoint, process, log):
        ready(endpoint, process)
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(str(endpoint))
        connection.sendall(b'{"jsonrpc":"2.0",')
        connection.close()
        assert client.request(endpoint, 'info')['engine'] == 'WKWebView'
        connection = raw_request(endpoint, 'evaluate', {'expression': 'Promise.resolve(42)'})
        connection.shutdown(socket.SHUT_WR)
        with connection.makefile('rb') as reader:
            assert json.loads(reader.readline())['result']['value'] == 42
        connection.close()
        connection = raw_request(endpoint, 'evaluate', {'expression': 'fetch(' + json.dumps(url) + ').then(() => window.finishedEvaluation = true)'})
        assert started.wait(5), 'evaluation never started'
        connection.close()
        begin = time.monotonic()
        assert client.request(endpoint, 'info')['engine'] == 'WKWebView'
        assert time.monotonic() - begin < 3, 'disconnected evaluation monopolized server'
        release.set()
        deadline = time.monotonic() + 10
        while not client.request(endpoint, 'evaluate', {'expression':'window.finishedEvaluation === true'})['value']:
            assert time.monotonic() < deadline
            time.sleep(.02)
        release.clear()
        started.clear()
        connection = raw_request(endpoint, 'navigate', {'url':url})
        assert started.wait(5)
        connection.close()
        begin = time.monotonic()
        assert client.request(endpoint, 'info')['engine'] == 'WKWebView'
        assert time.monotonic() - begin < 3, 'disconnected navigation monopolized server'
        release.set()
        deadline = time.monotonic() + 10
        while client.request(endpoint, 'info')['loading']:
            assert time.monotonic() < deadline
            time.sleep(.02)
        connection = raw_request(endpoint, 'evaluate', {'expression': "'x'.repeat(16 * 1024 * 1024)"}, size=4096)
        connection.recv(100)
        connection.close()
        assert client.request(endpoint, 'info')['engine'] == 'WKWebView'
        client.request(endpoint, 'close')
        finished(process, log)
    print('PASS: partial-request, pending-evaluation/navigation, and partial-response disconnect recovery')


def input_validation():
    with host() as (folder, endpoint, process, log):
        ready(endpoint, process)
        command(endpoint, 'eval:window.publicEvalMarker = 42')
        assert client.request(endpoint, 'evaluate', {'expression':'publicEvalMarker'})['value'] == 42
        path = folder / 'space # percent% question? otter🦦.html'
        path.write_text('<!doctype html><title>special path loaded</title>')
        command(endpoint, 'file:' + str(path))
        deadline = time.monotonic() + 10
        while client.request(endpoint, 'evaluate', {'expression':'document.title'})['value'] != 'special path loaded':
            assert time.monotonic() < deadline
            time.sleep(.02)
        text = 'quotes"\\\n\x00🦦'
        expression = """window.responses = []; turf._handleNativeMessage = message => responses.push(message);
            turf.send({type:'echo',data:{message:TEXT}});
            turf.send({type:'custom',data:{message:TEXT}});
            turf.send({type:'get_random',data:{min:2,max:1}});
            turf.send({type:'get_random',data:{min:42,max:42}}); null""".replace('TEXT', json.dumps(text))
        client.request(endpoint, 'evaluate', {'expression': expression})
        deadline = time.monotonic() + 10
        while len(result := client.request(endpoint, 'evaluate', {'expression':'responses'})['value']) < 3:
            assert time.monotonic() < deadline, result
            time.sleep(.02)
        assert result == [{'type':'echo_response','data':{'message':'Echo: ' + text}},
                          {'type':'custom_response','data':{'message':'Received: ' + text}},
                          {'type':'random_response','data':{'value':42}}], result
        client.request(endpoint, 'close')
        finished(process, log)
    print('PASS: special file paths, escaped native responses, invalid/equal random bounds')



def overload_and_navigation():
    with host() as (folder, endpoint, process, log):
        ready(endpoint, process)
        client.request(endpoint, 'evaluate', {'expression': "window.seen=0; console.error = () => { throw new Error('intentional logging failure'); }; turf._handleNativeMessage = m => { seen++; if(seen === 1) throw new Error('intentional handler failure'); }; null"})
        command(endpoint, 'flood')
        log.seek(0)
        accepted = int(re.search(r'FLOOD_ACCEPTED (\d+)', log.read())[1])
        assert 0 < accepted <= 2048, accepted
        deadline = time.monotonic() + 10
        while client.request(endpoint, 'evaluate', {'expression':'seen'})['value'] != accepted:
            assert time.monotonic() < deadline, accepted
            time.sleep(.02)
        assert client.request(endpoint, 'evaluate', {'expression':'__turf_message_queue.length'})['value'] == 0
        page = folder / 'next.html'
        page.write_text("""<!doctype html><title>replacement document</title>
            <script>window.received=[]; addEventListener('load', () => {
                turf._handleNativeMessage = message => received.push(message);
            });</script>""")
        command(endpoint, 'navigate-flood:' + page.as_uri())
        deadline = time.monotonic() + 10
        while not client.request(endpoint, 'evaluate', {'expression': "document.title === 'replacement document' && document.readyState === 'complete'"})['value']:
            assert time.monotonic() < deadline
            time.sleep(.02)
        command(endpoint, 'send-new')
        deadline = time.monotonic() + 10
        while not (received := client.request(endpoint, 'evaluate', {'expression':'received'})['value']):
            assert time.monotonic() < deadline
            time.sleep(.02)
        assert received == [{'type':'new-page', 'data':True}], received
        command(endpoint, 'prototype')
        deadline = time.monotonic() + 10
        while len(received := client.request(endpoint, 'evaluate', {'expression':'received'})['value']) < 2:
            assert time.monotonic() < deadline
            time.sleep(.02)
        assert received[1] == {'type':'prototype', 'data':{'__proto__':{'marker':True}}}, received
        assert client.request(endpoint, 'evaluate', {'expression':'Object.getPrototypeOf(received[1].data) === Object.prototype'})['value']
        client.request(endpoint, 'close')
        finished(process, log)
    print(f'PASS: hidden-page overload bounded to {accepted} accepted messages; handler exception isolation; no old-page messages after navigation')


def thread_contract():
    result = subprocess.run([str(ROOT / 'zig-out/bin/embedder-lifecycle'), '/tmp/unused-turf-test.sock', 'wrong-thread'], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and 'WRONG_THREAD_REJECTED' in result.stderr, result
    print('PASS: off-main-thread window initialization rejected before native UI work')


if __name__ == '__main__':
    repeated_lifecycle()
    shutdown_pending()
    disconnects()
    input_validation()
    overload_and_navigation()
    thread_contract()
