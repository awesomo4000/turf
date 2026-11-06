#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""One-shot topic delivery through the native macOS server, without showing a window."""
import json
import subprocess
import tempfile
from pathlib import Path
from automation_macos import ROOT, client, expect_error
from automation_diagnostics_macos import wait


def main():
    with tempfile.TemporaryDirectory(prefix='turf-emit-', dir='/tmp') as directory:
        folder = Path(directory)
        page = folder / 'page.html'
        page.write_text('''<!doctype html><script>
        window.events=[];
        window.addEventListener('turf-ready',()=>{window.catchall=turf.on('*',(data,meta)=>events.push({data,meta}));},{once:true});
        </script><p>Topic fixture</p>''')
        other = folder / 'other.html'
        other.write_text(page.read_text())
        endpoint = folder / 'control.sock'
        with (folder / 'host.log').open('w+') as log:
            process = subprocess.Popen([str(ROOT/'zig-out/bin/turf'), '--start-hidden', '--no-focus',
                '--automation-socket', str(endpoint)], stdout=log, stderr=log)
            try:
                wait(lambda: endpoint.exists() or process.poll() is not None)
                assert process.poll() is None
                def evaluate(source):
                    return client.request(endpoint, 'evaluate', {'expression': source}).get('value')
                wait(lambda: evaluate('document.readyState === "complete" && typeof turf.on === "function"'))
                wait(lambda: not client.request(endpoint, 'info')['loading'])
                assert client.request(endpoint, 'emit', {'topic':'startup','data':None})['handlers'] == 0
                client.request(endpoint, 'navigate', {'url':page.as_uri()})
                assert client.request(endpoint, 'info')['capabilities']['emit']
                def emit(topic, data, **options):
                    return client.request(endpoint, 'emit', dict(topic=topic, data=data, **options))
                evaluate('window.quietOff=turf.on("quiet",()=>{}); quietOff();')
                values = [None, False, 0, [], {}, '"\\\n\u2028\u2029</script>${globalThis.pwned=1}🦦',
                          {'__proto__': {'polluted': True}, 'constructor': 1}]
                for value in values:
                    result = emit('__proto__', value)
                    assert result['handlers'] == 1 and result['failures'] == 0, result
                    assert evaluate('events.at(-1).data') == value
                assert evaluate('typeof pwned + ":" + typeof ({}).polluted') == 'undefined:undefined'
                evaluate('window.off = turf.on("state", (d,m)=>events.push({data:d,meta:m}));')
                result = emit('state', {'n': 1}, retain=True)
                assert result['handlers'] == 2 and result['retained']
                evaluate('off(); window.late=[]; turf.on("state", (d,m)=>late.push({d,m}));')
                assert evaluate('late[0].m.replayed') is True
                assert evaluate('late[0].d.n') == 1
                evaluate('turf.on("bad",()=>{throw Error("fixture")}); turf.on("bad",()=>{window.survived=true});')
                result = emit('bad', 42)
                assert result['handlers'] == 3 and result['failures'] == 1
                assert evaluate('survived') is True
                evaluate('turf.on("mutate",d=>{d.x=99}); turf.on("mutate",d=>{window.original=d.x});')
                emit('mutate', {'x': 1})
                assert evaluate('original') == 1
                client.request(endpoint, 'diagnostics', {'action':'start'})
                client.request(endpoint, 'diagnostics', {'action':'stop'})
                client.request(endpoint, 'navigate', {'url':page.as_uri()})
                assert evaluate('events.length') == 1, evaluate('({events,href:location.href,api:typeof turf.on})')
                assert evaluate('events[0].data.n') == 1
                assert evaluate('events[0].meta.replayed') is True
                client.request(endpoint, 'navigate', {'url':other.as_uri()})
                assert evaluate('events.length') == 0, 'retained state leaked to another URL'
                client.request(endpoint, 'navigate', {'url':page.as_uri()})
                client.request(endpoint, 'emit', {'topic':'state', 'clear':True})
                evaluate('window.cleared=[]; turf.on("state",d=>cleared.push(d));')
                assert evaluate('cleared.length') == 0
                client.request(endpoint, 'navigate', {'url':page.as_uri()})
                assert evaluate('events.length') == 0
                for params in [{}, {'topic':'x'}, {'topic':'*','data':1}, {'topic':'','data':1},
                               {'topic':'x','data':1,'retain':1}, {'topic':'x','data':1,'clear':True},
                               {'topic':'x'*257,'data':1}]:
                    expect_error(endpoint, 'emit', params, -32602)
                cli = [str(ROOT/'zig-out/bin/turfctl'), str(endpoint), 'emit']
                def run(args, stdin=None):
                    r = subprocess.run(cli+args, input=stdin, text=True, encoding='utf-8', capture_output=True)
                    assert r.returncode == 0, r.stderr
                    return json.loads(r.stdout)
                assert run(['cli', '-', '--retain'], json.dumps(values))['retained']
                assert evaluate('events.at(-1).data') == values
                datafile = folder/'data.json'; datafile.write_text('false')
                run(['cli', '--data-file', str(datafile)])
                assert evaluate('events.at(-1).data') is False
                bad = subprocess.run(cli+['cli', '{invalid'], text=True, capture_output=True)
                assert bad.returncode == 1 and not bad.stdout
                run(['cli', 'null'])
                assert evaluate('events.at(-1).data') is None
                run(['{"topic":"cli","clear":true}'])
                subprocess.run([str(ROOT/'zig-out/bin/turfctl-library-test'), str(endpoint), 'emit'], check=True)
                emit('hostile', values, retain=True)
                client.request(endpoint, 'navigate', {'url':page.as_uri()})
                assert evaluate('events.at(-1).data') == values
                client.request(endpoint, 'emit', {'topic':'hostile','clear':True})
                evaluate('catchall()')
                assert emit('unobserved', 1)['handlers'] == 0
                for n in range(128): emit('limit'+str(n), n, retain=True)
                expect_error(endpoint, 'emit', {'topic':'overflow','data':1,'retain':True}, -32004)
                for n in range(128): client.request(endpoint,'emit',{'topic':'limit'+str(n),'clear':True})
                for n in range(5):
                    params = {'topic':'large'+str(n),'data':'a'*900000,'retain':True}
                    if n < 4: client.request(endpoint,'emit',params)
                    else: expect_error(endpoint,'emit',params,-32004)
                client.request(endpoint, 'close')
                assert process.wait(timeout=10) == 0
                print('PASS: JSON values, safe topics, listeners, retention/reload/URL scope, clear, limits, CLI stdin/file')
            except BaseException:
                log.seek(0); print(log.read()); raise
            finally:
                if process.poll() is None: process.kill(); process.wait()


if __name__ == '__main__': main()
