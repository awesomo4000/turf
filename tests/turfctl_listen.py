#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Deterministic polling-client tests using a disposable Unix socket."""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

ROOT=Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='turf-listen-',dir='/tmp') as directory:
        endpoint=Path(directory)/'control.sock'
        errors=[]
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as server:
            server.bind(str(endpoint)); server.listen(); server.settimeout(10)
            def serve():
                try:
                    for i in range(3):
                        with server.accept()[0] as connection:
                            connection.settimeout(10)
                            request=json.loads(connection.makefile('rb').readline())
                            assert request['method']=='recv'
                            params=request['params']
                            response={'jsonrpc':'2.0','id':request['id']}
                            if i==0:
                                assert params=={'topic':'*','limit':256}
                                response['result']={'session':'one','nextCursor':10,'droppedSinceCursor':5,
                                    'messages':[{'topic':'cmd','seq':10,'ts':0,'data':'old'}]}
                            elif i==1:
                                assert params=={'topic':'cmd','after':10,'session':'one'}
                                response['result']={'session':'one','nextCursor':11,'droppedSinceCursor':0,
                                    'messages':[{'topic':'cmd','seq':11,'ts':0,'data':'new'}]}
                            else:
                                assert params=={'topic':'cmd','after':11,'session':'one'}
                                response['error']={'code':-32004,'message':'Publish session changed'}
                            connection.sendall(json.dumps(response).encode()+b'\n')
                except BaseException as e: errors.append(e)
            thread=threading.Thread(target=serve,daemon=True); thread.start()
            result=subprocess.run([str(ROOT/'zig-out/bin/turfctl'),str(endpoint),'listen','cmd','--from-now'],
                capture_output=True,text=True,timeout=10)
            thread.join(10)
            assert not thread.is_alive() and not errors, errors
            assert result.returncode==1
            assert [json.loads(line)['data'] for line in result.stdout.splitlines()]==['new'], result
            assert json.loads(result.stderr)['code']==-32004, result
    print('PASS: listen skips initial backlog/loss, advances cursors, emits JSONL, and stops on session change')


if __name__=='__main__': main()
