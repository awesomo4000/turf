#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""One-shot topic delivery through the native macOS server, without showing a window."""
import json
import subprocess
import tempfile
import time
import statistics
from pathlib import Path
from automation_macos import ROOT, client, expect_error
from automation_diagnostics_macos import wait


def main():
    def topic_api(path):
        text = path.read_text()
        return text[text.index('    // Topic events'):text.index('    // Export functions')]
    assert topic_api(ROOT/'src/web/turf.js') == topic_api(ROOT/'src/web/platforms/windows/turf.js')
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
                wait(lambda: evaluate('events.length') == 1)
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
                wait(lambda: evaluate('events.length') > 0)
                assert evaluate('events.at(-1).data') == values
                client.request(endpoint, 'emit', {'topic':'hostile','clear':True})
                evaluate('catchall()')
                assert emit('unobserved', 1)['handlers'] == 0
                # Signals remove a group, including wildcards; explicit unsubscribe is idempotent.
                evaluate('window.ac=new AbortController(); window.calls=[]; '
                         'turf.on("sig",()=>calls.push(1),{signal:ac.signal}); '
                         'turf.on("sig",()=>calls.push(2),{signal:ac.signal}); '
                         'turf.on("other",()=>calls.push(3),{signal:ac.signal}); '
                         'window.offSignal=turf.on("*",()=>calls.push(4),{signal:ac.signal});')
                assert emit('sig', 1)['handlers'] == 3
                evaluate('offSignal(); offSignal(); ac.abort();')
                assert emit('sig', 2)['handlers'] == 0
                assert emit('other', 2)['handlers'] == 0
                emit('sig', 3, retain=True)
                evaluate('window.replays=[]; turf.on("sig",d=>replays.push(d),{signal:ac.signal})();')
                assert evaluate('replays.length') == 0
                evaluate('window.fresh=new AbortController(); turf.on("sig",d=>replays.push(d),{signal:fresh.signal});')
                assert evaluate('replays') == [3]
                evaluate('fresh.abort()')
                for value in ['null', '{}', '{aborted:false}', 'new EventTarget()', '42', '"signal"']:
                    assert evaluate('(()=>{try { turf.on("sig",()=>{}, {signal:' + value + '}); return false; } '
                                    'catch(e) {return e instanceof TypeError;}})()')
                # A dispatch snapshots listeners before calling any of them.
                evaluate('window.mid=new AbortController(); window.order=[]; '
                         'turf.on("mid",()=>{order.push(1);mid.abort()},{signal:mid.signal}); '
                         'turf.on("mid",()=>order.push(2),{signal:mid.signal});')
                assert emit('mid', 1)['handlers'] == 2
                assert evaluate('order') == [1, 2]
                assert emit('mid', 2)['handlers'] == 0
                # Cross-realm signals and callbacks from a replaced iframe.
                evaluate('window.frame=document.createElement("iframe"); document.body.append(frame); '
                         'window.cross=new frame.contentWindow.AbortController(); '
                         'window.frameCalls=0; turf.on("cross",()=>frameCalls++,{signal:cross.signal});')
                assert emit('cross', 1)['handlers'] == 1
                evaluate('cross.abort(); frame.remove();')
                assert emit('cross', 2)['handlers'] == 0
                client.request(endpoint, 'emit', {'topic':'sig','clear':True})
                for n in range(128): emit('limit'+str(n), n, retain=True)
                expect_error(endpoint, 'emit', {'topic':'overflow','data':1,'retain':True}, -32004)
                for n in range(128): client.request(endpoint,'emit',{'topic':'limit'+str(n),'clear':True})
                for n in range(5):
                    params = {'topic':'large'+str(n),'data':'a'*900000,'retain':True}
                    if n < 4: client.request(endpoint,'emit',params)
                    else: expect_error(endpoint,'emit',params,-32004)
                # Exercise replacement with a large unrelated retained set: emit should
                # serialize only the changed topic, then replay the latest on reload.
                timings=[]
                for n in range(1000):
                    before=time.monotonic()
                    emit('fast', n, retain=True)
                    timings.append(time.monotonic()-before)
                first=statistics.median(timings[:100]); last=statistics.median(timings[-100:])
                assert last < max(first*4, .03), (first,last)
                print(f'PASS: 1000 retained updates, first/last median {first*1000:.2f}/{last*1000:.2f} ms')
                client.request(endpoint, 'navigate', {'url':page.as_uri()})
                wait(lambda: evaluate('events.some(e=>e.meta.topic === "fast" && e.data === 999)'))
                assert evaluate('events.filter(e=>e.meta.topic === "fast").length') == 1
                # Independent polling cursors, JSON scalar handling, and filtering.
                assert client.request(endpoint,'info')['capabilities']['publish']
                initial=client.request(endpoint,'recv')
                assert initial['messages'] == [] and initial['nextCursor'] == 0
                evaluate('turf.publish("cmd", {action:"snapshot"}); turf.publish("other", false); turf.publish("cmd", null);')
                wait(lambda: client.request(endpoint,'recv')['nextCursor'] == 3)
                batch=client.request(endpoint,'recv',{'topic':'cmd','limit':1})
                assert batch['messages'][0]['data'] == {'action':'snapshot'}
                cursor=batch['nextCursor']; session=batch['session']
                tail=client.request(endpoint,'recv',{'topic':'cmd','after':cursor,'session':session})
                assert [e['data'] for e in tail['messages']] == [None]
                assert tail['nextCursor'] == 3
                assert client.request(endpoint,'recv',{'topic':'cmd','limit':1}) == batch
                expect_error(endpoint,'recv',{'after':1},-32602)
                expect_error(endpoint,'recv',{'session':'stale'},-32004)
                for params in [{'after':-1},{'after':True},{'limit':0},{'limit':257},{'topic':''}]:
                    expect_error(endpoint,'recv',params,-32602)
                for expression in ['turf.publish("*",1)', 'turf.publish("cmd",undefined)',
                                   'turf.publish("cmd", "x".repeat(65537))', 'turf.publish("cmd",1n)']:
                    assert evaluate('(()=>{try {'+expression+';return false;}catch(e){return true;}})()')
                # Two CLI listeners do not hold the server connection between polls.
                listeners=[]
                try:
                    for index in range(2):
                        output=(folder/f'listen{index}.jsonl').open('w+')
                        errors=(folder/f'listen{index}.err').open('w+')
                        proc=subprocess.Popen([str(ROOT/'zig-out/bin/turfctl'),str(endpoint),'listen','cmd'],stdout=output,stderr=errors)
                        listeners.append((proc,output,errors))
                    wait(lambda: all((folder/f'listen{i}.jsonl').stat().st_size>0 for i in range(2)))
                    evaluate('turf.publish("cmd", {action:"fresh"})')
                    wait(lambda: all('fresh' in (folder/f'listen{i}.jsonl').read_text() for i in range(2)))
                    assert client.request(endpoint,'info')['engine'] == 'WKWebView'
                    assert emit('live', 1)['accepted']
                finally:
                    for proc,output,errors in listeners:
                        proc.terminate(); proc.wait(timeout=5); output.close(); errors.close()
                before=client.request(endpoint,'recv')['nextCursor']
                evaluate('for(let i=0;i<300;i++) turf.publish("flood",i)')
                wait(lambda: client.request(endpoint,'recv',{'limit':256})['nextCursor'] == before+300)
                flooded=client.request(endpoint,'recv',{'after':before,'session':session,'limit':256})
                assert len(flooded['messages']) == 256 and flooded['droppedSinceCursor'] == 44
                assert flooded['messages'][0]['data'] == 44 and flooded['messages'][-1]['data'] == 299
                failed=subprocess.run([str(ROOT/'zig-out/bin/turfctl'),str(endpoint),'listen','cmd'],capture_output=True,text=True,timeout=5)
                assert failed.returncode == 1 and 'messages_dropped' in failed.stderr and not failed.stdout
                # Byte bound is independent of the message-count bound.
                before=client.request(endpoint,'recv',{'limit':256})['nextCursor']
                evaluate('for(let i=0;i<20;i++) turf.publish("bytes", "x".repeat(60000))')
                wait(lambda: client.request(endpoint,'recv',{'limit':256})['nextCursor'] == before+20)
                large=client.request(endpoint,'recv',{'after':before,'session':session,'limit':256})
                assert 0 < len(large['messages']) < 20
                assert large['droppedSinceCursor'] == 20-len(large['messages'])
                assert all(len(entry['data'])==60000 for entry in large['messages'])
                client.request(endpoint, 'close')
                assert process.wait(timeout=10) == 0
                print('PASS: emit/signals, retention, publish validation/count/byte limits, independent cursors, and concurrent listeners')
            except BaseException:
                log.seek(0); print(log.read()); raise
            finally:
                if process.poll() is None: process.kill(); process.wait()


if __name__ == '__main__': main()
