#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Local-file iframe rendering and read-scope checks using disposable files only."""
import html
import json
import os
from pathlib import Path
import subprocess
import tempfile

from automation_macos import ROOT, client
from automation_diagnostics_macos import wait
from embedder_failure_modes_macos import host, ready, command, finished
from screenshot_contract import raster


def check(api, placement, visible):
    # A fresh webview for every case avoids carrying earlier file-read grants.
    with host() as (folder, endpoint, process, log):
        ready(endpoint, process)
        pages = folder/'page root'; pages.mkdir()
        nested = pages/'nested'; nested.mkdir()
        outside = folder/'outside'; outside.mkdir()
        child = (outside if placement == 'outside' else nested if placement == 'nested' else pages)/'child # café.html'
        child_html = '<!doctype html><style>html,body{margin:0;background:#00ff00}</style><script>console.log("child ready");parent.postMessage("child-ready","*")</script>'
        child.write_text(child_html, encoding='utf-8')
        attribute = 'srcdoc="'+html.escape(child_html, quote=True)+'"' if placement == 'srcdoc' else 'src="'+child.as_uri()+'"'
        page = pages/'host.html'
        page.write_text('<!doctype html><title>File iframe fixture</title>'
            '<script>window.messages=[];addEventListener("message",e=>messages.push(e.data));'
            'addEventListener("load",()=>window.fixtureReady=true);</script>'
            '<iframe id="frame" style="width:120px;height:80px;border:0" '+attribute+'></iframe>', encoding='utf-8')
        screens = client.request(endpoint,'screens')['screens']
        selected = [screen for screen in screens if os.environ['TURF_TEST_SCREEN'].casefold() in screen['name'].casefold()]
        assert len(selected) == 1
        work = selected[0]['workArea']; frame = client.request(endpoint,'info')['window']['frame']
        client.request(endpoint,'move',{'screen':selected[0]['id'],'x':(work['width']-frame['width'])/2,
                                       'y':work['height']*5/6-frame['height']/2})
        if visible:
            shown = client.request(endpoint,'show')
            assert shown['visible'] and not shown['focused']
        client.request(endpoint,'diagnostics',{'action':'start'})
        if api == 'navigate': client.request(endpoint,'navigate',{'url':page.as_uri()})
        else: command(endpoint,'file:'+str(page))
        def evaluate(source): return client.request(endpoint,'evaluate',{'expression':source})['value']
        wait(lambda: evaluate('document.title === "File iframe fixture" && window.fixtureReady === true'))
        loaded = placement != 'outside'
        if loaded:
            wait(lambda: evaluate('messages.includes("child-ready")'))
        else:
            assert evaluate('messages.length === 0')
            assert evaluate('document.querySelector("#frame").contentWindow.location.href') == 'about:blank'
        shot = client.request(endpoint,'screenshot',{'selector':'#frame'})
        rows = raster(shot)
        pixel = list(rows[len(rows)//2][(shot['width']//2)*4:(shot['width']//2)*4+4])
        assert pixel == ([0,255,0,255] if loaded else [255,255,255,255]), (api,placement,visible,pixel)
        entries = client.request(endpoint,'diagnostics')['entries']
        child_logs = [entry for entry in entries if not entry['isMainFrame'] and entry.get('args') == ['child ready']]
        assert bool(child_logs) is loaded, entries
        # Painting and DOM access are separate: file frames may have opaque origins.
        if placement in ('same','nested'):
            access = evaluate('(()=>{try{return document.querySelector("#frame").contentWindow.location.href}catch(e){return e.name}})()')
            assert access in ('SecurityError',child.as_uri()), access
        pid = process.pid
        client.request(endpoint,'close'); finished(process,log)
        print(f'PASS: {api}, {placement}, visible={visible}: '+('rendered and executed' if loaded else 'outside read scope, blank frame'))
        return pid


def main():
    assert os.environ.get('TURF_TEST_SCREEN','').strip(), 'Set TURF_TEST_SCREEN'
    with tempfile.TemporaryDirectory(prefix='turf-file-iframe-focus-',dir='/tmp') as directory:
        folder=Path(directory); observer=folder/'observer'; focus=folder/'focus.jsonl'
        subprocess.run(['clang','-fobjc-arc','-framework','Cocoa',str(ROOT/'tests/automation_focus_guard.m'),'-o',str(observer)],check=True)
        with focus.open('w') as output:
            guard=subprocess.Popen([str(observer)],stdout=output)
            try:
                wait(lambda: focus.stat().st_size > 0)
                pids=[check(api,placement,visible) for visible in (False,True)
                      for api in ('file','navigate') for placement in ('same','nested','outside','srcdoc')]
                rows=[json.loads(line) for line in focus.read_text().splitlines()]
                assert not any(row['pid'] in pids for row in rows), rows
                print('PASS: all file iframe cases preserved focus')
            finally:
                guard.terminate();guard.wait(timeout=5)


if __name__ == '__main__': main()
