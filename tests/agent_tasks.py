#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Prepare or verify an agent trial against an explicitly supplied test socket.

The supervisor runs this tool. Give agents its prompt output and CLI --help,
not the task manifest or oracle code. Record the actual command transcript.
"""
import argparse
import json
from pathlib import Path
from automation_macos import ROOT, client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify'])
    parser.add_argument('--socket', required=True)
    parser.add_argument('--task', required=True)
    parser.add_argument('--fixture-url', help='Loopback HTTP URL for diagnostics.html; required for prepare')
    parser.add_argument('--answer', type=Path)
    parser.add_argument('--transcript', type=Path)
    args = parser.parse_args()
    tasks = json.loads((ROOT/'tests/agent_tasks.json').read_text())
    task = next((t for t in tasks if t['id'] == args.task), None)
    if task is None:
        parser.error('Unknown task; choices: ' + ', '.join(t['id'] for t in tasks))
    if args.action == 'prepare':
        if not args.fixture_url:
            parser.error('prepare requires --fixture-url from your loopback fixture server')
        client.request(args.socket, 'diagnostics', {'action':'start'})
        client.request(args.socket, 'navigate', {'url':args.fixture_url})
        print(json.dumps({'task':task['id'], 'prompt':task['prompt'], 'socket':args.socket,
                          'cli':str(ROOT/'tools/turf-client.py'),
                          'rules':['Use only the supplied socket and CLI help.', 'Do not inspect source files.',
                                   'Record every command and its output.', 'Keep focus with the user.']}, indent=2))
    else:
        if args.answer is None or args.transcript is None:
            parser.error('verify requires --answer and --transcript')
        answer = json.loads(args.answer.read_text())
        passed = all(answer.get(k) == v for k,v in task['answer'].items())
        if 'oracle' in task:
            actual = client.request(args.socket, 'evaluate', {'expression':task['oracle']})
            passed = passed and actual.get('value') is True
        report = {'task':task['id'], 'answerAndStatePassed':passed,
                  'transcript':str(args.transcript), 'transcriptBytes':args.transcript.stat().st_size,
                  'manualReviewRequired':['Verify commands support the answer; check claimed independent reads.',
                                          'Count commands, source-inspection attempts, target guesses and fixed sleeps.',
                                          'Record model/version, effort, elapsed time, help usage and failure recovery.']}
        print(json.dumps(report, indent=2))
        if not passed:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
