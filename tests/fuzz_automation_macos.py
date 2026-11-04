#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Seeded mutation fuzzing of the real macOS socket parser; no window is shown.

Only info, unknown methods, and deliberately invalid parameter requests are sent.
Failure artifacts retain exact wire bytes for --replay. This is mutation testing,
not coverage-guided fuzzing of Objective-C.
"""
import argparse
import json
import math
import random
import socket
import subprocess
import tempfile
from pathlib import Path

from automation_macos import ROOT, client
from embedder_lifecycle_macos import wait_endpoint


def encode(value):
    return json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode()


def cases(seed, count):
    rng = random.Random(seed)
    values = [None, True, False, 0, -1, 1e300, '', '🦦\x00\n"\\', [], {}, [1, None]]
    base = {'jsonrpc': '2.0', 'id': 1, 'method': 'info'}
    # Stable regression corpus comes before random mutations.
    for value in values:
        yield encode(value), None
    for field in ('jsonrpc', 'id', 'method', 'params'):
        for value in values:
            yield encode({**base, field: value}), None
    for method, key in [('evaluate', 'expression'), ('navigate', 'url')]:
        for value in values:
            if not isinstance(value, str):
                yield encode({**base, 'method': method, 'params': {key: value}}), -32602
    for raw in [b'', b'{', b'\xff', b'{}garbage', b'{"id":NaN}', b'{"id":1e9999}',
                b'[' * 512 + b']' * 512, b'{"jsonrpc":"2.0","id":1,"method":"missing\\u0000"}']:
        yield raw, None
    # Apple rejects unpaired UTF-16 surrogates; Python's JSON decoder accepts them.
    yield b'{"jsonrpc":"2.0","id":1,"method":"info","extra":"\\ud83e"}', -32700
    for _ in range(count):
        value = dict(base)
        value['method'] = rng.choice(['info', 'fuzz_unknown_method'])
        for _ in range(rng.randrange(1, 5)):
            key = rng.choice(['jsonrpc', 'id', 'method', 'params', 'extra'])
            if rng.randrange(5) == 0:
                value.pop(key, None)
            else:
                value[key] = rng.choice(values)
        raw = bytearray(encode(value))
        for _ in range(rng.randrange(4)):
            if raw:
                index = rng.randrange(len(raw))
                if rng.randrange(2):
                    del raw[index:index + rng.randrange(1, 8)]
                else:
                    raw[index] = rng.choice([0, 9, 13, 32, 34, 92, 127, 128, 255])
        # Newline is framing, so each case remains exactly one request.
        yield bytes(raw).replace(b'\n', b' '), None
    # Exercise request-length boundaries with valid, harmless JSON.
    prefix = b'{"jsonrpc":"2.0","id":1,"method":"info","padding":"'
    suffix = b'"}'
    for size in [(1 << 20) - 1, 1 << 20, (1 << 20) + 1]:
        yield prefix + b'x' * (size - len(prefix) - len(suffix)) + suffix, -32600 if size > 1 << 20 else 0


def finite_number(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError('outside portable JSON number range')
    return value


def reject_constant(text):
    raise ValueError(f'non-JSON constant: {text}')


def check(endpoint, raw, expected, index):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(endpoint))
        wire = raw + b'\n'
        # Split across writes to exercise partial frames, including in UTF-8/escapes.
        split = min(len(wire), index % 31 + 1)
        connection.sendall(wire[:split])
        try:
            connection.sendall(wire[split:])
        except BrokenPipeError:
            pass  # Oversized input may be rejected before the final bytes.
        response = connection.makefile('rb').readline((1 << 20) + 1)
    result = json.loads(response)
    assert result.get('jsonrpc') == '2.0', result
    assert ('result' in result) != ('error' in result), result
    if 'error' in result:
        assert isinstance(result['error'].get('code'), int), result
        assert isinstance(result['error'].get('message'), str), result
    # For syntactically valid generated envelopes, check the protocol contract,
    # not merely that the process survived. Byte-level malformed cases can have
    # parser-specific rejection details.
    try:
        request = json.loads(raw, parse_float=finite_number, parse_constant=reject_constant)
        json.dumps(request, ensure_ascii=False).encode("utf-8")
    except (ValueError, UnicodeError):
        request = None
    if isinstance(request, dict):
        valid_id = isinstance(request.get('id'), (str, int, float)) and not isinstance(request.get('id'), bool)
        if not valid_id or request.get('jsonrpc') != '2.0' or not isinstance(request.get('method'), str):
            if expected is None:
                expected = -32600
        elif 'params' in request and not isinstance(request['params'], dict):
            if expected is None:
                expected = -32602
        elif request['method'] == 'info' and len(raw) <= 1 << 20:
            expected = 0
            assert result['id'] == request['id'], result
        elif request['method'] not in ('evaluate', 'navigate', 'info'):
            if expected is None:
                expected = -32601
    elif request is not None and expected is None:
        expected = -32600
    if expected == 0:
        assert 'result' in result, result
    elif expected is not None:
        assert result.get('error', {}).get('code') == expected, result
    # A malformed request must not poison the next connection or kill the host.
    assert client.request(endpoint, 'info')['engine'] == 'WKWebView'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=int, default=20261103)
    parser.add_argument('--cases', type=int, default=2000)
    parser.add_argument('--replay', type=Path)
    args = parser.parse_args()
    assert args.cases >= 0
    corpus = cases(args.seed, args.cases)
    if args.replay:
        saved = json.loads(args.replay.read_text())
        corpus = [(bytes.fromhex(saved['wire_hex']), saved['expected'])]
    with tempfile.TemporaryDirectory(prefix='turf-fuzz-', dir='/tmp') as directory:
        folder = Path(directory)
        endpoint = folder / 'control.sock'
        with (folder / 'host.log').open('w+') as log:
            process = subprocess.Popen([str(ROOT / 'zig-out/bin/embedder-lifecycle'), str(endpoint)], stdout=log, stderr=log)
            index = -1
            try:
                wait_endpoint(endpoint, process)
                assert not client.request(endpoint, 'info')['window']['visible']
                for index, (raw, expected) in enumerate(corpus):
                    try:
                        check(endpoint, raw, expected, index)
                    except Exception as error:
                        output = ROOT / 'zig-out/fuzz-failures'
                        output.mkdir(parents=True, exist_ok=True)
                        artifact = output / f'automation-{args.seed}-{index}.json'
                        log.flush()
                        log.seek(0)
                        artifact.write_text(json.dumps({'seed': args.seed, 'index': index,
                            'wire_hex': raw.hex(), 'expected': expected, 'error': repr(error),
                            'host_log': log.read()}, indent=2))
                        raise AssertionError(f'Fuzz failure; replay with --replay {artifact}') from error
                client.request(endpoint, 'close')
                assert process.wait(timeout=10) == 0
                log.seek(0)
                assert 'QUEUE_DEINITIALIZED' in log.read()
                assert not endpoint.exists()
                print(f'PASS: {index + 1} protocol cases, seed={args.seed}; recovery and graceful teardown')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
