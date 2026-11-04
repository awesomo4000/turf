#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Shared structured-error and diagnostics contract for the real platform hosts."""
import json
import subprocess
import sys
import time
from automation_macos import ROOT, client


def wait(check, timeout=10):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = check()
        if last: return last
        time.sleep(.03)
    raise AssertionError(f'Condition timed out; last result: {last!r}')


def run_contract(endpoint, folder, fixture_url):
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
    for malformed in ('[]', '{"ok":true,"result":5}', '{"ok":false,"error":null}'):
        try:
            failure('window.savedJSON=JSON.stringify;JSON.stringify=()=>'+json.dumps(malformed)+';42', -32003, 'serialization_error')
        finally:
            evaluate('JSON.stringify=window.savedJSON;delete window.savedJSON')
    assert evaluate('42')['value'] == 42
    command = subprocess.run([sys.executable, str(ROOT/'tools/turf-client.py'), str(endpoint), 'evaluate', json.dumps({'expression':'throw new Error("cli failure")'})], capture_output=True, text=True)
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
    prepared = subprocess.run([sys.executable, task_tool, 'prepare', '--socket', str(endpoint), '--task', 'condition-wait', '--fixture-url', fixture_url], capture_output=True, text=True, check=True)
    assert 'oracle' not in json.loads(prepared.stdout)
    answer_file = folder/'answer.json'; answer_file.write_text('{"heading":"ready"}')
    transcript = folder/'transcript.jsonl'; transcript.write_text('{"source":"contract-test, not an agent trial"}\n')
    verify = [sys.executable, task_tool, 'verify', '--socket', str(endpoint), '--task', 'condition-wait', '--answer', str(answer_file), '--transcript', str(transcript)]
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
    for params in ({'after':True},{'after':None},{'after':-1},{'after':1e30},{'limit':None},{'limit':0},{'limit':257},{'action':None},{'action':'clear'}):
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
    # A different hostname gives this iframe a genuinely different origin.
    request('diagnostics', {'action':'start'})
    request('navigate', {'url':fixture_url})
    wait(lambda: evaluate('Boolean(document.querySelector("#child"))')['value'])
    child_url = fixture_url.replace('127.0.0.1','localhost').replace('diagnostics.html','child.html')
    evaluate('document.querySelector("#child").src='+json.dumps(child_url))
    wait(lambda: any(not e['isMainFrame'] and e['url']==child_url and 'child-startup' in json.dumps(e)
                     for e in request('diagnostics', {'limit':256})['entries']))
    probe = '''new Promise(resolve=>{
        const timer=setTimeout(()=>{removeEventListener('message',listener);resolve('probe timeout')},2000);
        function listener(event){if(event.source===document.querySelector('#child').contentWindow && typeof event.data?.diagnosticsProbe==='boolean'){
            clearTimeout(timer);removeEventListener('message',listener);resolve(event.data.diagnosticsProbe);
        }}
        addEventListener('message',listener);
        document.querySelector('#child').contentWindow.postMessage('probe-diagnostics','*');
    })'''
    assert evaluate(probe)['value'] is True
    request('diagnostics', {'action':'stop'})
    wait(lambda: evaluate(probe)['value'] is False)
    request('diagnostics', {'action':'start'})
    assert evaluate(probe)['value'] is False  # Existing subframes attach on navigation.
    request('diagnostics', {'action':'stop'})
    print('PASS: cross-origin frame capture, teardown and restart scope', flush=True)
    request('diagnostics', {'action':'start'})
    evaluate('window.previewGetterRan=false; console.log({get value(){window.previewGetterRan=true;throw Error("getter")}})')
    assert evaluate('window.previewGetterRan')['value'] is False
    # Multibyte previews hit the byte cap before the 256-entry cap.
    for _ in range(4):
        cursor = request('diagnostics')['latestCursor']
        evaluate('for(let i=0;i<60;i++) console.info("byte-limit", "é".repeat(1000), "é".repeat(1000), "é".repeat(1000))')
        wait(lambda: request('diagnostics')['latestCursor'] >= cursor+60)
    byte_limited = request('diagnostics', {'limit':256})
    assert 0 < len(byte_limited['entries']) < 240, byte_limited['bufferBytes']
    assert 512*1024 < byte_limited['bufferBytes'] <= byte_limited['maxBytes']
    assert byte_limited['droppedSinceCursor'] > 0
    request('diagnostics', {'action':'stop'})
    print('PASS: accessor-safe previews and byte-limit eviction', flush=True)
