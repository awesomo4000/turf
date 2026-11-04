#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Independent transport tests plus real-server CLI/library integration for turfctl."""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT/'zig-out/bin'/('turfctl.exe' if os.name == 'nt' else 'turfctl')
LIBRARY = ROOT/'zig-out/bin'/('turfctl-library-test.exe' if os.name == 'nt' else 'turfctl-library-test')


def cli(endpoint, method, params=None, *flags, input=None, success=True):
    args=[str(CTL),str(endpoint),method]
    if params is not None: args.append(json.dumps(params))
    result=subprocess.run([*args,*flags],input=input,capture_output=True,text=True,encoding="utf-8",timeout=120)
    assert (result.returncode == 0) is success, (args,result.returncode,result.stdout,result.stderr)
    assert not (result.stderr if success else result.stdout), result
    return json.loads(result.stdout if success else result.stderr)


@contextmanager
def fake_server(folder, handler, requests=1):
    endpoint = r'\\.\pipe\turfctl-test-'+uuid.uuid4().hex if os.name=='nt' else str(folder/('s-'+uuid.uuid4().hex[:8]))
    ready=threading.Event(); failures=[]
    def serve():
        try:
            for _ in range(requests):
                if os.name == 'nt':
                    import ctypes as c
                    from ctypes import wintypes as w
                    api=c.WinDLL('kernel32',use_last_error=True)
                    api.CreateNamedPipeW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.DWORD,c.c_void_p]
                    api.CreateNamedPipeW.restype=w.HANDLE
                    api.ConnectNamedPipe.argtypes=[w.HANDLE,c.c_void_p]
                    api.ReadFile.argtypes=[w.HANDLE,c.c_void_p,w.DWORD,c.POINTER(w.DWORD),c.c_void_p]
                    api.WriteFile.argtypes=api.ReadFile.argtypes
                    api.CloseHandle.argtypes=[w.HANDLE]
                    handle=api.CreateNamedPipeW(endpoint,3,0,1,65536,65536,0,None)
                    assert handle != c.c_void_p(-1).value
                    ready.set()
                    try:
                        assert api.ConnectNamedPipe(handle,None) or c.get_last_error()==535
                        def receive():
                            buffer=c.create_string_buffer(65536); count=w.DWORD()
                            if not api.ReadFile(handle,buffer,len(buffer),c.byref(count),None): return b''
                            return buffer.raw[:count.value]
                        def send(data):
                            offset=0
                            while offset<len(data):
                                buffer=c.create_string_buffer(data[offset:offset+65536]); count=w.DWORD()
                                if not api.WriteFile(handle,buffer,len(buffer)-1,c.byref(count),None): return
                                offset+=count.value
                        wire=bytearray()
                        while b'\n' not in wire:
                            chunk=receive()
                            if not chunk: break
                            wire.extend(chunk)
                        handler(bytes(wire),send)
                    finally: api.CloseHandle(handle)
                else:
                    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as listener:
                        listener.bind(endpoint); listener.listen(); listener.settimeout(10); ready.set()
                        with listener.accept()[0] as connection:
                            connection.settimeout(10)
                            wire=bytearray()
                            while b'\n' not in wire:
                                chunk=connection.recv(65536)
                                if not chunk: break
                                wire.extend(chunk)
                            def send(data):
                                try: connection.sendall(data)
                                except (BrokenPipeError,ConnectionResetError): pass
                            handler(bytes(wire),send)
                    os.unlink(endpoint)
        except BaseException as error: failures.append(error); ready.set()
    worker=threading.Thread(target=serve,daemon=True);worker.start();assert ready.wait(5)
    try: yield endpoint
    finally:
        worker.join(12)
        assert not worker.is_alive(), 'fake server did not finish'
        if failures: raise failures[0]


def envelope(result): return json.dumps({'jsonrpc':'2.0','id':1,'result':result},separators=(',',':')).encode()+b'\n'


def transport_tests():
    with tempfile.TemporaryDirectory(prefix='turfctl-test-',dir=None if os.name=='nt' else '/tmp') as directory:
        folder=Path(directory)
        packet=envelope({'unicode':'otter 🦦','value':42})
        def fragmented(wire,send):
            assert json.loads(wire)['params']=={'quoted':'"\\\n🦦'}
            for offset in range(0,len(packet),3): send(packet[offset:offset+3])
        with fake_server(folder,fragmented) as endpoint:
            assert cli(endpoint,'info',{'quoted':'"\\\n🦦'})=={'unicode':'otter 🦦','value':42}
        for wire in (b'[]\n',b'not JSON\n',b'{"jsonrpc":"2.0","id":2,"result":1}\n',b'{"jsonrpc":"2.0","id":1,"result":1,"error":{}}\n',b'{"jsonrpc":"2.0","id":1,"error":{"code":true,"message":"bad"}}\n',b'{"jsonrpc":"2.0","id":1,"result":1}'):
            with fake_server(folder,lambda _,send:send(wire)) as endpoint:
                assert cli(endpoint,'info',success=False)['kind']=='client_error'
        error={'code':-32002,'message':'boom','data':{'stack':'preserved'}}
        with fake_server(folder,lambda _,send:send(json.dumps({'jsonrpc':'2.0','id':1,'error':error}).encode()+b'\n')) as endpoint:
            assert cli(endpoint,'evaluate',{'expression':'throw 1'},success=False)==error
        with fake_server(folder,lambda _,send:time.sleep(.5)) as endpoint:
            start=time.monotonic(); result=cli(endpoint,'info',None,'--timeout-ms','100',success=False)
            assert result['message']=='Timeout' and time.monotonic()-start<3, result
        # The response limit includes JSON bytes but excludes the delimiter.
        overhead=len(envelope(''))-1
        large='x'*(32*1024*1024-overhead)
        with fake_server(folder,lambda _,send:send(envelope(large))) as endpoint:
            assert len(cli(endpoint,'info'))==len(large)
        with fake_server(folder,lambda _,send:send(b'x'*(32*1024*1024+1)+b'\n')) as endpoint:
            assert cli(endpoint,'info',success=False)['message']=='ResponseTooLarge'
        params=folder/'boundary.json'
        overhead=len(json.dumps({'jsonrpc':'2.0','id':1,'method':'info','params':{'x':''}},separators=(',',':')))
        padding='x'*(1024*1024-overhead)
        params.write_text(json.dumps({'x':padding},separators=(',',':')))
        def request_boundary(wire,send):
            assert len(wire)==1024*1024+1;send(envelope(True))
        with fake_server(folder,request_boundary) as endpoint:
            assert cli(endpoint,'info',None,'--params-file',str(params)) is True
        params.write_text(json.dumps({'x':padding+'x'},separators=(',',':')))
        assert cli('unused','info',None,'--params-file',str(params),success=False)['message']=='RequestTooLarge'
        assert cli('unused','info',[],success=False)['message']=='ParamsMustBeObject'
        params=folder/'oversized.json';params.write_text(json.dumps({'x':'x'*(1024*1024)}))
        assert cli('unused','info',None,'--params-file',str(params),success=False)['kind']=='client_error'
        # Invalid screenshot output must not replace an existing destination.
        output=folder/'keep.bin';output.write_bytes(b'keep')
        with fake_server(folder,lambda _,send:send(envelope({'format':'png','data':'%%%'}))) as endpoint:
            cli(endpoint,'screenshot',{},'-o',str(output),success=False)
        assert output.read_bytes()==b'keep'
        # Streaming stdout must preserve the current offset in redirected files.
        out=folder/'stdout';out.write_bytes(b'prefix\n')
        with fake_server(folder,lambda _,send:send(envelope(42))) as endpoint, out.open('ab',buffering=0) as stream:
            subprocess.run([str(CTL),endpoint,'info'],stdout=stream,check=True,timeout=10)
        assert out.read_bytes()==b'prefix\n42\n'
        source=folder/'stdin';source.write_bytes(b'header\n{"a":42}')
        def stdin_check(wire,send):
            assert json.loads(wire)['params']=={'a':42};send(envelope(True))
        with fake_server(folder,stdin_check) as endpoint, source.open('rb',buffering=0) as stream:
            assert stream.readline()==b'header\n'
            result=subprocess.run([str(CTL),endpoint,'info','--params-file','-'],stdin=stream,capture_output=True,check=True,timeout=10)
            assert json.loads(result.stdout) is True
    print('PASS: fragmented transport, strict envelopes, RPC details, deadline, response limits, atomic failure, streaming stdio',flush=True)


def integration(endpoint, folder):
    from reference_client import request
    assert cli(endpoint,'info')['engine']==request(endpoint,'info')['engine']
    assert cli(endpoint,'screens')==request(endpoint,'screens')
    assert cli(endpoint,'evaluate',{'expression':'Promise.resolve({text:"🦦",answer:42})'})['value']=={'text':'🦦','answer':42}
    assert cli(endpoint,'evaluate',None,'--expression-file','-',input='Promise.resolve(42)')['value']==42
    script=folder/'input.js';script.write_text('({text:"café"})',encoding='utf-8')
    assert cli(endpoint,'evaluate',None,'--expression-file',str(script))['value']['text']=='café'
    assert cli(endpoint,'evaluate',None,'--params-file','-',input='{"expression":"6*7"}')['value']==42
    failure=cli(endpoint,'evaluate',{'expression':'throw new Error("turfctl failure")'},success=False)
    assert failure['code']==-32002 and failure['data']['name']=='Error'
    image=folder/'crop.png'
    shot=cli(endpoint,'screenshot',{'selector':'#target','padding':2},'-o',str(image))
    original=request(endpoint,'screenshot',{'selector':'#target','padding':2})
    assert image.read_bytes()==base64.b64decode(original['data']) and shot['region']==original['region']
    assert 'data' not in shot
    output=folder/'blob.bin'; size=33*1024*1024+17
    metadata=cli(endpoint,'grab',{'source':f'new Uint8Array({size}).fill(137)'},'-o',str(output))
    assert metadata['bytes']==size and output.stat().st_size==size
    assert hashlib.sha256(output.read_bytes()).digest()==hashlib.sha256(bytes([137])*size).digest()
    assert cli(endpoint,'evaluate',{'expression':"Object.keys(window).filter(k=>k.startsWith('__turfGrab_')).length"})['value']==0
    assert cli(endpoint,'grab',{'source':"'data:text/plain;base64,b3R0ZXI='",'chunkBytes':2},'-o',str(output))['bytes']==5
    assert output.read_bytes()==b'otter'
    cli(endpoint,'grab',{'source':'throw new Error("failed grab")'},'-o',str(output),success=False)
    assert output.read_bytes()==b'otter'
    # Fail inside the actual read operation after preparation, then verify cleanup.
    before=set(folder.iterdir())
    cli(endpoint,'evaluate',{'expression':"window.originalRead=FileReader.prototype.readAsDataURL; FileReader.prototype.readAsDataURL=function(){throw new Error('interrupted chunk')}; true"})
    try:
        cli(endpoint,'grab',{'source':'new Uint8Array(1024)','chunkBytes':128},'-o',str(output),success=False)
        assert output.read_bytes()==b'otter'
    finally:
        cli(endpoint,'evaluate',{'expression':'FileReader.prototype.readAsDataURL=originalRead;true'})
    assert cli(endpoint,'evaluate',{'expression':"Object.keys(window).filter(k=>k.startsWith('__turfGrab_')).length"})['value']==0
    assert set(folder.iterdir())==before, 'failed grab left temporary files'
    cli(endpoint,'grab',{'source':'new Blob(["data"])'},'-o',str(folder/'missing'/'output'),success=False)
    assert cli(endpoint,'evaluate',{'expression':"Object.keys(window).filter(k=>k.startsWith('__turfGrab_')).length"})['value']==0
    assert cli(endpoint,'grab',{'source':'new Blob([])'},'-o',str(output))['bytes']==0
    assert output.read_bytes()==b''
    info=cli(endpoint,'info'); window_info=info['window']
    cli(endpoint,'resize',info['viewport'])
    cli(endpoint,'move',{'screen':window_info['screen'],'x':window_info['x'],'y':window_info['y']})
    assert not cli(endpoint,'show')['focused']
    cli(endpoint,'diagnostics',{'action':'start'})
    cli(endpoint,'navigate',{'url':'about:blank'})
    cli(endpoint,'evaluate',{'expression':"document.body.innerHTML='<button id=button>click</button><textarea id=editor></textarea>'; window.clicked=false; document.querySelector('#button').onclick=()=>window.clicked=true; console.log('turfctl diagnostic marker'); true"})
    point=cli(endpoint,'evaluate',{'expression':"(()=>{const r=document.querySelector('#button').getBoundingClientRect();return {x:r.x+5,y:r.y+5}})()"})['value']
    if info['engine']=='WebKitGTK':
        assert cli(endpoint,'click',point,success=False)['code']==-32004
        assert cli(endpoint,'key',{'key':'Enter'},success=False)['code']==-32004
    else:
        cli(endpoint,'click',point)
        assert cli(endpoint,'evaluate',{'expression':'window.clicked'})['value']
    cli(endpoint,'evaluate',{'expression':"document.querySelector('#editor').focus();true"})
    cli(endpoint,'typeText',{'text':'otter 🦦'})
    if info['engine']!='WebKitGTK': cli(endpoint,'key',{'key':'Enter'})
    assert cli(endpoint,'evaluate',{'expression':"document.querySelector('#editor').value.startsWith('otter 🦦')"})['value']
    entries=cli(endpoint,'diagnostics',{})['entries']
    assert any('turfctl diagnostic marker' in entry.get('args',[]) for entry in entries)
    cli(endpoint,'diagnostics',{'action':'stop'})
    subprocess.run([str(LIBRARY),str(endpoint)],check=True,timeout=15)
    print('PASS: real CLI, file/stdin evaluation, regional PNG, 33 MiB grab, tiny chunks, failure cleanup, empty blob, Zig library',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary',nargs='?',type=Path,default=ROOT/'zig-out/bin'/('turf.exe' if os.name=='nt' else 'turf'))
    parser.add_argument('--transport-only',action='store_true')
    args=parser.parse_args()
    transport_tests()
    if args.transport_only: return
    if sys.platform=='darwin':
        from screenshot_regions_macos import window
    else:
        from screenshot_regions_portable import window
    if os.name == 'nt':
        from automation_windows_protocol import test_directory
        temporary = test_directory()
    else:
        temporary = tempfile.TemporaryDirectory(prefix='turfctl-live-',dir='/tmp')
    with temporary as directory:
        with window(args.binary.resolve(),Path(directory)) as opened:
            endpoint=opened[0] if isinstance(opened,tuple) else opened
            integration(endpoint,Path(directory))

if __name__=='__main__': main()
