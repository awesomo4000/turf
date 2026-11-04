#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Run diagnostics against the native Linux or Windows host, no debug port."""
import functools
import http.server
import json
import os
import socket
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from diagnostics_contract import ROOT, client, run_contract


def main():
    assert sys.platform != 'darwin', 'Use the macOS runner with explicit display placement'
    binary = Path(sys.argv[1] if len(sys.argv)>1 else ROOT/'zig-out/bin/turf').resolve()
    if os.name == 'nt':
        from automation_windows_protocol import test_directory
        directory = test_directory()
    else:
        directory = tempfile.TemporaryDirectory(prefix='turf-diagnostics-',dir='/tmp')
    with directory as name:
        folder = Path(name)
        endpoint = r'\\.\pipe\turf-diagnostics-' + uuid.uuid4().hex if os.name == 'nt' else str(folder/'control.sock')
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self,*args): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(ROOT/'tests/fixtures/automation')))
        thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        env={**os.environ,'WEBVIEW2_USER_DATA_FOLDER':str(folder/'profile')}
        with (folder/'host.log').open('w+') as log:
            process=subprocess.Popen([str(binary),'--no-focus','--automation-socket',endpoint],env=env,stdout=log,stderr=log)
            try:
                deadline=time.monotonic()+20
                while True:
                    assert process.poll() is None, 'Host exited'
                    try:
                        info=client.request(endpoint,'info'); break
                    except (OSError,RuntimeError):
                        if time.monotonic()>deadline: raise
                        time.sleep(.05)
                assert info['capabilities']['structuredErrors'] and info['capabilities']['diagnostics']
                run_contract(endpoint,folder,f'http://127.0.0.1:{server.server_port}/diagnostics.html')
                # Abandon starts without reading their replies. Installation may
                # finish before disconnect; either outcome must leave a usable server.
                for _ in range(4):
                    client.request(endpoint,'diagnostics',{'action':'stop'})
                    payload=b'{"jsonrpc":"2.0","id":91,"method":"diagnostics","params":{"action":"start"}}\n'
                    if os.name == 'nt':
                        with open(endpoint,'r+b',buffering=0) as connection: connection.write(payload)
                    else:
                        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
                            connection.connect(endpoint); connection.sendall(payload)
                    deadline=time.monotonic()+10
                    while True:
                        try:
                            client.request(endpoint,'diagnostics',{'action':'start'}); break
                        except RuntimeError as error:
                            assert json.loads(str(error))['code']==-32000, error
                            assert time.monotonic()<deadline
                            time.sleep(.03)
                    client.request(endpoint,'evaluate',{'expression':'console.log("after abandoned start")'})
                    deadline=time.monotonic()+10
                    while not any('after abandoned start' in json.dumps(e) for e in client.request(endpoint,'diagnostics')['entries']):
                        assert time.monotonic()<deadline
                        time.sleep(.03)
                client.request(endpoint,'diagnostics',{'action':'stop'})
                print('PASS: abandoned diagnostics starts and recovery',flush=True)
                try:
                    client.request(endpoint,'evaluate',{'expression':'new Promise(resolve=>setTimeout(()=>{window.late=(window.late||0)+1;resolve(1)},31000))'})
                except RuntimeError as error:
                    result=json.loads(str(error)); assert result['code']==-32001 and result['data']=={'kind':'timeout','mayStillRun':True},result
                else: raise AssertionError('Expected timeout')
                deadline=time.monotonic()+10
                while client.request(endpoint,'evaluate',{'expression':'window.late === 1'})['value'] is not True:
                    assert time.monotonic()<deadline
                    time.sleep(.05)
                client.request(endpoint,'close'); assert process.wait(timeout=10)==0
                print('PASS: structured errors, diagnostics, timeout/late completion and shutdown on '+info['engine'],flush=True)
            except BaseException:
                log.seek(0); print(log.read())
                try: print(json.dumps(client.request(endpoint,'diagnostics'),indent=2))
                except Exception: pass
                raise
            finally:
                if process.poll() is None: process.terminate(); process.wait(timeout=10)
                server.shutdown(); server.server_close(); thread.join(timeout=5)

if __name__ == '__main__': main()
