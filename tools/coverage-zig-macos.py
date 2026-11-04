#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Validate kcov's Zig line mapping, then measure Turf using the macOS GUI suites."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, cwd=ROOT, **kwargs)


def lines_from_report(path):
    files = {}
    tree = ET.parse(path)
    roots = [Path(item.text) for item in tree.findall('./sources/source') if item.text]
    for item in tree.findall('.//class'):
        source = Path(item.attrib['filename'])
        if not source.is_absolute():
            candidates = {(root/source).resolve() for root in roots if (root/source).is_file()}
            if len(candidates) != 1:
                raise RuntimeError('Cannot resolve coverage source: '+str(source))
            source = candidates.pop()
        else:
            source = source.resolve()
        counts = files.setdefault(source, {})
        for line in item.findall('./lines/line'):
            number, hits = int(line.attrib['number']), int(line.attrib['hits'])
            counts[number] = max(counts.get(number, 0), hits)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig', help='Zig 0.17.0 executable')
    parser.add_argument('--kcov', default='kcov')
    parser.add_argument('--output', type=Path, default=ROOT/'zig-out/coverage-zig-macos')
    args = parser.parse_args()
    if sys.platform != 'darwin': parser.error('This runner requires native macOS')
    if not os.environ.get('TURF_TEST_SCREEN','').strip(): parser.error('Set TURF_TEST_SCREEN to a unique display-name substring')
    kcov = shutil.which(args.kcov)
    if not kcov: parser.error('kcov is not installed or not on PATH')
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=args.output.resolve()))
    print('Zig coverage artifacts: '+str(output), flush=True)
    probe = ROOT/'tests/fixtures/coverage/branch_probe.zig'
    binary = output/'probe'
    run([args.zig,'build-exe',probe,'-lc','-O','Debug','-fno-strip',f'-femit-bin={binary}'])
    source = probe.read_text().splitlines()
    hit = next(i for i,line in enumerate(source,1) if '// HIT' in line)
    miss = next(i for i,line in enumerate(source,1) if '// MISS' in line)
    for other in (False, True):
        env = os.environ.copy(); env.pop('TURF_COVERAGE_TAKE_OTHER',None)
        if other: env['TURF_COVERAGE_TAKE_OTHER']='1'
        report = output/('probe-other' if other else 'probe-normal')
        run([kcov,f'--include-path={probe.parent}',report,binary],env=env,timeout=60)
        counts = lines_from_report(report/'probe/cobertura.xml').get(probe.resolve(),{})
        expected_hit, expected_miss = (miss,hit) if other else (hit,miss)
        if counts.get(expected_hit,0) <= 0 or counts.get(expected_miss) != 0:
            raise RuntimeError(f'Unreliable Zig mapping: {counts}; expected hit={expected_hit}, miss={expected_miss}')
    print('PASS: known Zig hit/miss lines, both directions, in separate reports',flush=True)
    run([args.zig,'build','-Doptimize=Debug','--prefix',output/'install'])
    host = output/'install/bin/turf'
    report = output/'report'
    wrapper = output/'launch-turf.py'
    command = [kcov,f'--include-path={ROOT / "src"}','--exclude-pattern=.m,.h',str(report),str(host)]
    wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\ncommand='+repr(command)+'\nos.execv(command[0], command+sys.argv[1:])\n')
    wrapper.chmod(0o700)
    env = {**os.environ,'TURF_TEST_BINARY':str(wrapper)}
    env.pop('LLVM_PROFILE_FILE',None)
    tests = ['tests/automation_diagnostics_macos.py','tests/deferred_show_macos.py']
    for test in tests: run([sys.executable,test],env=env)
    files = lines_from_report(report/'turf/cobertura.xml')
    rows = []
    for path, counts in sorted(files.items()):
        if path.suffix != '.zig' or not path.is_relative_to(ROOT/'src'):
            raise RuntimeError('Non-project Zig source in coverage totals: '+str(path))
        covered = sum(hits>0 for hits in counts.values())
        rows.append({'file':str(path.relative_to(ROOT)),'covered':covered,'mappedLines':len(counts)})
    if not rows or not any(row['covered'] for row in rows): raise RuntimeError('No project Zig execution was measured')
    covered = sum(row['covered'] for row in rows); total = sum(row['mappedLines'] for row in rows)
    summary = '\n'.join(f"{row['covered']:4}/{row['mappedLines']:4} {100*row['covered']/row['mappedLines']:6.2f}%  {row['file']}" for row in rows)
    summary += f'\nTOTAL {covered}/{total} mapped lines: {100*covered/total:.2f}%\n'
    (output/'summary.txt').write_text(summary)
    metadata = {'scope':'Emitted runtime Zig lines on macOS only; excludes omitted functions, comptime, other backends, Objective-C, JavaScript, stdlib and dependencies. Not branch coverage.',
                'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'probePassed':True,
                'binary':str(host),'tests':tests,'files':rows,'covered':covered,'mappedLines':total,
                'zig':subprocess.check_output([args.zig,'version'],text=True).strip(),
                'kcov':subprocess.check_output([kcov,'--version'],text=True).strip()}
    (output/'run.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(summary,flush=True)
    print('HTML report: '+str(report/'turf/index.html'),flush=True)


if __name__ == '__main__': main()
