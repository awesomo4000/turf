#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Real WKWebView region captures, raster comparisons, validation, and focus checks."""
import argparse
import base64
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

from automation_macos import ROOT, client
from automation_diagnostics_macos import wait

SCENE = '''<style>
html,body { margin:0; width:100%; height:100%; overflow:hidden; }
body { background:repeating-linear-gradient(0deg,#123456 0px,#123456 5px,#abcdef 5px,#abcdef 10px); }
#target { position:absolute; left:40px; top:30px; width:120px; height:80px;
 background:linear-gradient(90deg,#ff0000 50%,#0000ff 50%); }
#inner { position:absolute; left:8px; top:9px; width:18px; height:22px; background:#00ff00; }
</style><div id="target" class="match"><div id="inner"></div></div>
<div class="match" style="position:absolute;left:250px;top:20px;width:20px;height:30px;background:#ff00ff"></div>
<div id="hidden" style="display:none"></div><div id="far" style="position:absolute;left:700px;top:500px;width:20px;height:20px"></div>
<iframe id="frame" style="position:absolute;left:230px;top:100px;width:160px;height:80px;border:0" srcdoc="<style>body{margin:0;background:#ffee00}</style><div id='frame-child'>inside</div>"></iframe>'''


def raster(shot):
    """Decode the native 8-bit RGB/RGBA PNGs with stdlib only, for pixel assertions."""
    data = base64.b64decode(shot['data'], validate=True)
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height, depth, kind, compression, filtering, interlace = struct.unpack('>IIBBBBB', data[16:29])
    assert (width, height) == (shot['width'], shot['height'])
    assert depth == 8 and kind in (2, 6) and interlace == 0, (depth, kind, interlace)
    channels = 4 if kind == 6 else 3
    packed = bytearray()
    offset = 8
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        if data[offset+4:offset+8] == b'IDAT':
            packed.extend(data[offset+8:offset+8+length])
        offset += 12 + length
    raw = zlib.decompress(packed)
    stride = width * channels
    assert len(raw) == (stride + 1) * height
    previous = bytearray(stride)
    rows = []
    for y in range(height):
        start = y * (stride + 1)
        mode, row = raw[start], bytearray(raw[start+1:start+1+stride])
        for i in range(stride):
            left = row[i-channels] if i >= channels else 0
            up, corner = previous[i], previous[i-channels] if i >= channels else 0
            if mode == 0: predictor = 0
            elif mode == 1: predictor = left
            elif mode == 2: predictor = up
            elif mode == 3: predictor = (left + up) // 2
            elif mode == 4:
                p = left + up - corner
                distances = (abs(p-left), abs(p-up), abs(p-corner))
                predictor = (left, up, corner)[distances.index(min(distances))]
            else: raise AssertionError(mode)
            row[i] = (row[i] + predictor) & 255
        if channels == 4:
            rows.append(bytes(row))
        else:
            rows.append(b''.join(row[i:i+3] + b'\xff' for i in range(0, stride, 3)))
        previous = row
    return rows


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


def contract(endpoint, folder, baseline):
    def request(params=None): return client.request(endpoint, 'screenshot', params)
    def evaluate(source): return client.request(endpoint, 'evaluate', {'expression':source})['value']
    def error(params, code, selector=None, message=None):
        try: request(params)
        except RuntimeError as failure:
            value = json.loads(str(failure))
            assert value['code'] == code, value
            if message is not None:
                assert value['message'] == message, value
            if selector is not None:
                assert selector in value['message'] and value['data']['selector'] == selector, value
        else: raise AssertionError(f'Expected screenshot error: {params}')
    info = client.request(endpoint, 'info')
    assert info['capabilities']['screenshotRegion'] is True
    viewport = info['viewport']
    full = request()
    assert full['region'] == {'x':0,'y':0,**viewport}
    assert request({}) == full, 'static no-argument screenshot changed'
    if baseline:
        assert {k:v for k,v in full.items() if k != 'region'} == baseline, 'legacy PNG response fields changed'
    full_rows = raster(full)
    sx, sy = full['width']/viewport['width'], full['height']/viewport['height']
    assert sx == sy

    def compare(params, region):
        shot = request(params)
        assert shot['region'] == region, (params, shot['region'], region)
        assert shot['width'] == round(region['width']*sx) and shot['height'] == round(region['height']*sy), shot['region']
        x, y = round(region['x']*sx), round(region['y']*sy)
        expected = [row[x*4:(x+shot['width'])*4] for row in full_rows[y:y+shot['height']]]
        assert raster(shot) == expected, f'Crop pixels differ from viewport at {region}'
        return shot

    region = {'x':40,'y':30,'width':120,'height':80}
    rect = compare({'rect':region}, region)
    selector = compare({'selector':'#target'}, region)
    assert rect == selector
    assert compare({'selector':'.match'}, region) == selector, 'selector did not use first match'
    compare({'selector':'#target','padding':7}, {'x':33,'y':23,'width':134,'height':94})
    compare({'rect':region,'padding':7}, {'x':33,'y':23,'width':134,'height':94})
    compare({'selector':'#target','padding':10000}, {'x':0,'y':0,**viewport})
    w,h = viewport['width'],viewport['height']
    for input_rect, result in [
        ({'x':-10,'y':20,'width':30,'height':40}, {'x':0,'y':20,'width':20,'height':40}),
        ({'x':20,'y':-10,'width':30,'height':40}, {'x':20,'y':0,'width':30,'height':30}),
        ({'x':w-10,'y':20,'width':30,'height':40}, {'x':w-10,'y':20,'width':10,'height':40}),
        ({'x':20,'y':h-10,'width':30,'height':40}, {'x':20,'y':h-10,'width':30,'height':10}),
        ({'x':40.25,'y':30.75,'width':9.5,'height':10.5}, {'x':40,'y':30,'width':10,'height':12}),
    ]:
        compare({'rect':input_rect}, result)
    iframe = evaluate('(()=>{const r=document.querySelector("#frame").getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height}})()')
    compare({'selector':'#frame'}, iframe)
    error({'selector':'#frame-child'}, -32004, '#frame-child')
    for selector_text in ('#missing', 'body[data-value="quote\\\\text"]'):
        error({'selector':selector_text}, -32004, selector_text)
    error({'selector':'['}, -32602, '[')
    for selector_text in ('#hidden', '#far'):
        error({'selector':selector_text}, -32602)
    error({'rect':region,'selector':'#target'}, -32602,
          message='rect and selector are mutually exclusive; provide only one')
    error({'padding':0}, -32602, message='padding requires rect or selector')
    invalid = [
        {'rect':region,'selector':'#target'}, {'padding':0}, {'padding':1},
        {'selector':None}, {'selector':4}, {'selector':''}, {'rect':None}, {'rect':[]},
        {'rect':{}}, {'rect':{**region,'width':0},'padding':100}, {'rect':{**region,'height':-1}},
        {'rect':{**region,'x':True}}, {'rect':{**region,'width':'20'}},
        {'rect':{**region,'x':1e308,'width':1e308}},
        {'rect':{**region,'x':w}}, {'rect':{**region,'y':h}},
        {'rect':{'x':-20,'y':0,'width':10,'height':10}},
        {'rect':{'x':0,'y':-20,'width':10,'height':10}},
    ]
    invalid += [{'rect':region,'padding':value} for value in (-1, True, '8', None)]
    for params in invalid: error(params, -32602)
    # The generic CLI must forward crop options and retain region metadata.
    output = folder / 'selector.png'
    completed = subprocess.run([sys.executable, str(ROOT/'tools/turf-client.py'), str(endpoint),
        'screenshot', json.dumps({'selector':'#target'}), '-o', str(output)], capture_output=True, text=True, check=True)
    result = json.loads(completed.stdout)
    assert result['region'] == region and result['width'] == selector['width']
    assert output.read_bytes() == base64.b64decode(selector['data'])
    assert request()['data'] == full['data'], 'capture changed the page'
    evaluate("window.savedQuery = Document.prototype.querySelector; window.savedRect = Element.prototype.getBoundingClientRect; Document.prototype.querySelector = () => {throw Error('page override')}; Element.prototype.getBoundingClientRect = () => {throw Error('page override')}; true")
    assert request({'selector':'#target'}) == selector, 'page overrides affected isolated measurements'
    evaluate("Document.prototype.querySelector = savedQuery; Element.prototype.getBoundingClientRect = savedRect; document.body.style.zoom = '1.25'; true")
    evaluate("new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
    measured = evaluate("(() => { const r = document.querySelector('#target').getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height, vw:innerWidth,vh:innerHeight}; })()")
    zoom_rect = {key:measured[key] * viewport['width' if key in ('x','width') else 'height'] / measured['vw' if key in ('x','width') else 'vh'] for key in ('x','y','width','height')}
    zoom_region = {'x':math.floor(zoom_rect['x']), 'y':math.floor(zoom_rect['y'])}
    zoom_region.update(width=math.ceil(zoom_rect['x']+zoom_rect['width'])-zoom_region['x'], height=math.ceil(zoom_rect['y']+zoom_rect['height'])-zoom_region['y'])
    full_rows = raster(request())
    assert compare({'selector':'#target'}, zoom_region) == compare({'rect':zoom_rect}, zoom_region)
    print('PASS: isolated DOM measurements and CSS zoom coordinates/pixels')
    print(f'PASS: native rect/selector PNG pixels, first match, padding, all edges, fractional bounds, iframe scope, errors, CLI; scale={sx}')
    if baseline: print('PASS: no-parameter PNG bytes and existing fields exactly match pre-feature binary')


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
