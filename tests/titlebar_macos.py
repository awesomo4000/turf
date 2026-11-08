#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Native compact-window checks; --preview leaves an unfocused window on the chosen display."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from automation_macos import ROOT, client
from automation_diagnostics_macos import wait


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview',action='store_true')
    preview=parser.parse_args().preview
    if preview: assert os.environ.get('TURF_TEST_SCREEN'), 'Set TURF_TEST_SCREEN'
    folder=Path(tempfile.mkdtemp(prefix='turf-titlebar-',dir='/tmp'))
    native=folder/'native-test'
    subprocess.run(['clang','-fobjc-arc','-fblocks','-Wno-incompatible-pointer-types',
        '-framework','Cocoa','-framework','WebKit','-framework','CoreGraphics',
        str(ROOT/'tests/titlebar_macos.m'),str(ROOT/'src/platforms/macos/automation.m'),'-o',str(native)],check=True)
    subprocess.run([str(native)],check=True)
    page=folder/'preview.html'
    page.write_text('''<!doctype html><meta charset="utf-8"><style>
    *{box-sizing:border-box}body{margin:0;background:#f6f7f8;color:#24323b;font:16px system-ui}
    header{height:40px;padding:0 16px 0 88px;display:flex;align-items:center;gap:12px;background:#dce9e8}
    header button{font:13px system-ui;padding:4px 12px;border:1px solid #a6bcb9;border-radius:6px;background:white}
    main{padding:24px}h1{font-size:24px;margin:0 0 12px}p{line-height:1.5}
    input{font:inherit;padding:8px;width:100%}
    </style><header data-turf-drag><button id="button" onclick="this.textContent='Clicked'">Page button</button><span>𝓽𝓾𝓻𝓯</span></header>
    <main><h1>Content goes all the way up</h1><p>That colored header is part of the page.<br>Drag its blank area. Its button remains clickable.</p><input value="Page controls and text selection still work"></main>''')
    for mode in ['normal','hidden','no-controls','square']:
        endpoint=folder/(mode+'.sock')
        args=[str(ROOT/'zig-out/bin/turf'),'--titlebar',('normal' if mode=='normal' else 'hidden'),'--start-hidden','--no-focus','--automation-socket',str(endpoint)]
        if mode!='normal': args += ['--title','Turf window options preview']
        if mode in ('no-controls','square'): args += ['--window-controls','hidden']
        if mode=='square': args += ['--square-corners','--cmd-drag']
        with (folder/(mode+'.log')).open('w') as log:
            process=subprocess.Popen(args,stdout=log,stderr=log,start_new_session=True)
        keep=False
        try:
            wait(lambda:endpoint.exists() or process.poll() is not None)
            assert process.poll() is None
            def request(method,params=None): return client.request(endpoint,method,params)
            request('navigate',{'url':page.as_uri()})
            info=request('info')
            assert info['window']['titlebar']==('normal' if mode=='normal' else 'hidden')
            assert info['window']['windowControls']==('hidden' if mode in ('no-controls','square') else 'normal')
            assert info['window']['squareCorners']==(mode=='square')
            assert info['window']['cmdDrag']==(mode=='square')
            assert info['window']['title']==('Turf window options preview' if mode!='normal' else '𝓽𝓾𝓻𝓯')
            assert request('evaluate', {'expression':'document.querySelector("header").getBoundingClientRect().top'})['value']==0
            for width,height in [(520,300),(560,320)]:
                request('resize',{'width':width,'height':height})
                info=request('info')
                assert info['viewport']=={'width':width,'height':height},info
                def capture():
                    try: return request('screenshot')
                    except RuntimeError as error:
                        if json.loads(str(error))['code']==-32004: return None
                        raise
                shot=wait(capture)
                assert shot['region']['width']==width and shot['region']['height']==height
            if preview and mode=='square':
                screens=request('screens')['screens']
                matches=[s for s in screens if os.environ['TURF_TEST_SCREEN'].casefold() in s['name'].casefold()]
                assert len(matches)==1
                screen=matches[0]; work=screen['workArea']; frame=info['window']['frame']
                request('move',{'screen':screen['id'],'x':(work['width']-frame['width'])/2,'y':work['height']*5/6-frame['height']/2})
                request('evaluate',{'expression':'document.querySelector("header").style.paddingLeft="16px"; document.querySelector("h1").textContent="Square corners. No window controls."; document.querySelector("p").textContent="Hold Command and drag anywhere to move. Resize from an edge. Ordinary clicks and typing still work."'})
                request('show')
                assert not request('info')['window']['focused']
                wait(lambda: request('evaluate',{'expression':'document.visibilityState'})['value']=='visible')
                request('evaluate',{'expression':'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))'})
                point=request('evaluate',{'expression':'(()=>{const r=document.querySelector("button").getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()'})['value']
                request('click',point)
                wait(lambda: request('evaluate',{'expression':'document.querySelector("button").textContent'})['value']=='Clicked')
                request('evaluate',{'expression':'window.lastPrevented=null;document.addEventListener("mousedown",e=>window.lastPrevented=e.defaultPrevented)'})
                request('click',{'x':480,'y':20})
                wait(lambda: request('evaluate',{'expression':'lastPrevented'})['value'] is True)
                request('click',point)
                wait(lambda: request('evaluate',{'expression':'lastPrevented'})['value'] is False)
                request('evaluate',{'expression':'document.querySelector("header").setAttribute("data-turf-no-drag","")'})
                request('click',{'x':480,'y':20})
                assert request('evaluate',{'expression':'lastPrevented'})['value'] is False
                request('evaluate',{'expression':'document.querySelector("header").removeAttribute("data-turf-no-drag")'})
                request('click',{'x':100,'y':220})
                request('evaluate',{'expression':'document.querySelector("input").focus(); document.querySelector("input").value=""'})
                request('typeText',{'text':'Square window keyboard input 🦦'})
                assert request('evaluate',{'expression':'document.querySelector("input").value'})['value']=='Square window keyboard input 🦦'
                # A page script cannot initiate dragging with a synthetic mouse event.
                before=request('info')['window']['frame']
                assert request('evaluate',{'expression':'document.querySelector("header").dispatchEvent(new MouseEvent("mousedown",{bubbles:true,cancelable:true}))'})['value'] is True
                assert request('info')['window']['frame']==before
                keep=True
                print(json.dumps({'pid':process.pid,'endpoint':str(endpoint),'preview':'shown without focus'}))
            else:
                request('close'); assert process.wait(timeout=10)==0
        finally:
            if not keep and process.poll() is None: process.kill(); process.wait()
    print('PASS: title defaults/custom text, normal/hidden/control-free/square modes, viewport resize, and screenshot geometry')


if __name__=='__main__': main()
