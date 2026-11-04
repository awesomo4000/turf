#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Measure the macOS Objective-C bridge with the real automation integration tests."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig', help='Zig 0.17.0 executable')
    parser.add_argument('--output', type=Path, default=ROOT/'zig-out/coverage-macos', help='Parent for a fresh report directory')
    args = parser.parse_args()
    if sys.platform != 'darwin': parser.error('This runner requires native macOS')
    if not os.environ.get('TURF_TEST_SCREEN', '').strip():
        parser.error('Set TURF_TEST_SCREEN to a unique display-name substring')
    # Every run has its own profiles and binary; old results cannot inflate coverage.
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=args.output.resolve()))
    objects = output/'objects'; objects.mkdir()
    profiles = output/'profiles'; profiles.mkdir()
    print('Coverage artifacts: ' + str(output), flush=True)
    for name in ('cocoa_bridge','automation'):
        run(['xcrun','clang','-fobjc-arc','-g','-O0','-fprofile-instr-generate','-fcoverage-mapping',
             '-c',ROOT/f'src/platforms/macos/{name}.m','-o',objects/f'{name}.o'])
    bridge = objects/'libturf_coverage_bridge.dylib'
    # Keep profiling relocations and runtime under the same Apple linker.
    # The callbacks are exported by the Zig executable and resolved at load time.
    run(['xcrun','clang','-dynamiclib','-fprofile-instr-generate',objects/'cocoa_bridge.o',objects/'automation.o',
         '-framework','Cocoa','-framework','WebKit','-framework','CoreGraphics',
         '-Wl,-undefined,dynamic_lookup','-install_name',bridge,'-o',bridge])
    run([args.zig,'build','-Doptimize=Debug',f'-Dmacos-coverage-objects={objects}','--prefix',output/'install'])
    binary = output/'install/bin/turf'
    env = {**os.environ, 'TURF_TEST_BINARY': str(binary), 'LLVM_PROFILE_FILE': str(profiles/'turf-%p.profraw')}
    tests = ['tests/automation_diagnostics_macos.py','tests/deferred_show_macos.py']
    for test in tests:
        run([sys.executable, test], env=env)
    raw = sorted(profiles.glob('*.profraw'))
    if not raw: raise RuntimeError('Tests passed but the instrumented host produced no profiles')
    merged = output/'coverage.profdata'
    run(['xcrun','llvm-profdata','merge','-sparse',*raw,'-o',merged])
    common = [bridge, f'-instr-profile={merged}', '--sources', ROOT/'src/platforms/macos/cocoa_bridge.m', ROOT/'src/platforms/macos/automation.m']
    summary = subprocess.check_output(['xcrun','llvm-cov','report',*map(str,common)], text=True)
    (output/'summary.txt').write_text(summary)
    print(summary, flush=True)
    run(['xcrun','llvm-cov','show',*common,'-format=html',f'-output-dir={output / "html"}',
         '-show-line-counts-or-regions','-show-branches=count'])
    with (output/'coverage.json').open('w') as stream:
        run(['xcrun','llvm-cov','export',*common], stdout=stream)
    metadata = {'scope':'macOS Objective-C bridge only; excludes Zig, injected JavaScript, system frameworks, and browser engine',
                'binary':str(binary),'instrumentedBridge':str(bridge),'tests':tests,'profileCount':len(raw),
                'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'zig':subprocess.check_output([args.zig,'version'],text=True).strip(),
                'clang':subprocess.check_output(['xcrun','clang','--version'],text=True).strip()}
    (output/'run.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print('HTML report: '+str(output/'html/index.html'),flush=True)


if __name__ == '__main__': main()
