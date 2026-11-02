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
            def failure(source, code=-32002, kind='javascript_exception', message=None):
                try:
                    evaluate(source)
                except RuntimeError as error:
                    data = json.loads(str(error))
                    assert data['code'] == code, data
                    assert data['data']['kind'] == kind and data['data']['context'] == 'main', data
                    if message is not None:
                        assert message in data['message'], data
                    return data
                raise AssertionError('Expected failure: ' + source)
            info = request('info')
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

            assert evaluate('({answer:42,nested:[true,null]})')['value'] == {'answer':42,'nested':[True,None]}
            assert evaluate('let fixtureValue=4; fixtureValue+1')['value'] == 5
            assert evaluate('Promise.resolve(17)')['value'] == 17
            assert evaluate('undefined') == {'type':'undefined'}
            assert evaluate('null') == {'type':'null','value':None}
            detailed = failure('throw new Error("boom here")', message='boom here')
            assert detailed['data']['stack'] is None or isinstance(detailed['data']['stack'], str)
            assert detailed['data']['line'] is None or isinstance(detailed['data']['line'], (int,float))
            failure('Promise.reject(new TypeError("async boom"))', message='async boom')
            failure('let = ;', message=None)
            for expression, message in [('throw "text"','text'),('throw null','null'),('throw undefined','undefined'),('throw 42','42')]:
                failure(expression, message=message)
            failure('throw {get message(){throw Error("getter ran")},toString(){throw Error("conversion ran")}}', message='Thrown object')
            failure('throw new Proxy({}, {getOwnPropertyDescriptor(){throw Error("proxy trap")}})', message='Thrown object')
            error = failure('throw "x".repeat(100000)')
            assert len(error['message']) == 4096
            failure('const circle={};circle.self=circle;circle', -32003, 'serialization_error')
            failure('1n', -32003, 'serialization_error')
            failure('({toJSON(){throw new Error("serialize boom")}})', -32003, 'serialization_error', 'serialize boom')
            try:
                failure('window.savedJSON=JSON.stringify;JSON.stringify=()=>{throw Error("formatter broken")};42', kind='native_error')
            finally:
                evaluate('JSON.stringify=window.savedJSON;delete window.savedJSON')
            try:
                failure('window.savedJSON=JSON.stringify;JSON.stringify=()=>"[]";42', -32003, 'serialization_error')
            finally:
                evaluate('JSON.stringify=window.savedJSON;delete window.savedJSON')
            assert evaluate('42')['value'] == 42
            command = subprocess.run(['python3', str(ROOT/'tools/turf-client.py'), str(endpoint), 'evaluate', json.dumps({'expression':'throw new Error("cli failure")'})], capture_output=True, text=True)
            assert command.returncode != 0 and not command.stdout and 'cli failure' in command.stderr
            print('PASS: evaluation values, promises, syntax/throw/rejection, hostile objects, serialization, CLI exit', flush=True)

            assert evaluate('typeof window.turf')['value'] == 'object'
            assert request('diagnostics')['enabled'] is False
            start = request('diagnostics', {'action':'start'})
            assert request('diagnostics', {'action':'start'}) == start
            session = start['session']
            def read(after=0, limit=256):
                return request('diagnostics', {'session':session, 'after':after,'limit':limit})
            request('navigate', {'url': (ROOT/'tests/fixtures/automation/diagnostics.html').as_uri()})
            def messages():
                return read()['entries']
            wait(lambda: any('fixture-startup' in json.dumps(e) for e in messages()))
            wait(lambda: any(e['kind']=='error' for e in messages()))
            file_errors = [e for e in messages() if e['kind']=='error']
            assert any('timer-failure' in json.dumps(e) or 'Script error.' in json.dumps(e) for e in file_errors)
            request('navigate', {'url': fixture_url})
            wait(lambda: any(e['kind']=='error' and 'timer-failure' in json.dumps(e) for e in messages()))
            wait(lambda: any(e['kind']=='unhandledrejection' and 'rejection-failure' in json.dumps(e) for e in messages()))
            wait(lambda: any(not e['isMainFrame'] and 'child-startup' in json.dumps(e) for e in messages()))
            entries = messages()
            assert len({e['documentId'] for e in entries}) >= 2
            assert all(e['url'] and e['timestamp'] and e['receivedAt'] for e in entries)
            wait(lambda: evaluate('Boolean(document.querySelector("#delayed"))')['value'])
            failure('childReady', message='childReady')
            assert evaluate('document.querySelector("#child").contentWindow.childReady')['value'] is True
            evaluate('document.querySelector("#trigger").click()')
            wait(lambda: any('button-failure' in json.dumps(e) for e in messages()))
            # Flush any scheduled diagnostics before comparing independent reads.
            # Exercise the supervisor interface and its independent DOM oracle.
            task_tool = str(ROOT/'tests/agent_tasks.py')
            prepared = subprocess.run(['python3', task_tool, 'prepare', '--socket', str(endpoint), '--task', 'condition-wait', '--fixture-url', fixture_url], capture_output=True, text=True, check=True)
            assert 'oracle' not in json.loads(prepared.stdout)
            answer_file = folder/'answer.json'; answer_file.write_text('{"heading":"ready"}')
            transcript = folder/'transcript.jsonl'; transcript.write_text('{"source":"contract-test, not an agent trial"}\n')
            verify = ['python3', task_tool, 'verify', '--socket', str(endpoint), '--task', 'condition-wait', '--answer', str(answer_file), '--transcript', str(transcript)]
            assert subprocess.run(verify, capture_output=True).returncode == 1
            wait(lambda: evaluate('Boolean(document.querySelector("#delayed"))')['value'])
            evaluate('document.querySelector("h1").textContent=document.querySelector("#delayed").textContent')
            assert subprocess.run(verify, capture_output=True).returncode == 0
            before = read()['latestCursor']
            evaluate('console.log("independent-read")')
            wait(lambda: read(before)['entries'])
            first = read(before, 1)
            second = read(before, 1)
            assert first['entries'] == second['entries'] and first['nextCursor'] == second['nextCursor']
            assert not read(read()['latestCursor'])['entries']
            before = read()['latestCursor']
            evaluate('console.log("z".repeat(10000));const circular={};circular.self=circular;console.warn(circular)')
            wait(lambda: len(read(before)['entries']) >= 2)
            assert any(e['truncated'] for e in read(before)['entries'])
            # A synchronous burst tests the page queue; spaced batches test native eviction.
            evaluate('for(let i=0;i<1000;i++)console.log("burst",i)')
            wait(lambda: read()['droppedSinceCursor'] > 0)
            for batch in range(6):
                cursor = read()['latestCursor']
                evaluate(f'for(let i=0;i<60;i++)console.info("batch-{batch}",i)')
                wait(lambda: read()['latestCursor'] >= cursor + 60)
            flooded = read()
            assert len(flooded['entries']) <= 256 and flooded['bufferBytes'] <= flooded['maxBytes']
            assert flooded['droppedSinceCursor'] > 0
            sequences = [e['sequence'] for e in flooded['entries']]
            assert sequences == sorted(set(sequences))
            collected = []
            page_cursor = 0
            while page_cursor < flooded['latestCursor']:
                page = read(page_cursor, 7)
                assert page['nextCursor'] > page_cursor
                collected.extend(e['sequence'] for e in page['entries'])
                page_cursor = page['nextCursor']
            assert collected == sequences
            cursor = flooded['latestCursor']
            docs = {e['documentId'] for e in flooded['entries']}
            request('navigate', {'url':'about:blank'})
            wait(lambda: read(cursor)['entries'])
            assert any(e['documentId'] not in docs for e in read(cursor)['entries'])
            try:
                request('diagnostics', {'session':'stale-session'})
            except RuntimeError as error:
                assert json.loads(str(error))['code'] == -32004
            else: raise AssertionError('Stale session should fail')
            for params in ({'after':True},{'after':-1},{'after':1e30},{'limit':0},{'limit':257},{'action':'clear'}):
                try: request('diagnostics', params)
                except RuntimeError as error: assert json.loads(str(error))['code'] == -32602
                else: raise AssertionError(params)
            latest = read()['latestCursor']
            assert request('diagnostics', {'action':'stop'})['enabled'] is False
            evaluate('console.log("not captured")')
            assert read()['latestCursor'] == latest
            evaluate('window.beforeStartLog=console.log')
            restarted = request('diagnostics', {'action':'start'})
            assert restarted['session'] != session
            assert evaluate('console.log !== beforeStartLog')['value'] is True
            request('diagnostics', {'action':'stop'})
            assert evaluate('console.log === beforeStartLog')['value'] is True
            request('diagnostics', {'action':'start'})
            evaluate('window.externalLog=function(){window.forwarded=true}; console.log=externalLog')
            request('diagnostics', {'action':'stop'})
            assert evaluate('console.log === externalLog')['value'] is True
            evaluate('console.log=beforeStartLog')
            request('navigate', {'url':fixture_url})
            wait(lambda: evaluate('typeof window.turf')['value'] == 'object')
            assert request('diagnostics')['enabled'] is False
            print('PASS: startup/frame/errors, independent cursors, truncation, flooding, navigation, validation, stop/restart/restoration', flush=True)
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
            assert not any(e['pid']==process.pid for e in events), events
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
                    run(ROOT/'zig-out/bin/turf', folder, path, f'http://127.0.0.1:{server.server_port}/diagnostics.html')
                finally:
                    server.shutdown(); server.server_close(); thread.join(timeout=5)
            finally:
                observer.terminate();observer.wait(timeout=5)

if __name__=='__main__': main()
