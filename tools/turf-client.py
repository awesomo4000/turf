#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Send JSON-RPC to an explicitly named Turf Unix socket or Windows pipe."""
import argparse
import base64
import json
import os
import tempfile
import uuid
import socket
import sys
from pathlib import Path


def _pipe_exchange(path, payload):
    """Use overlapped Win32 I/O so an unresponsive pipe cannot hang the client."""
    import ctypes as c
    from ctypes import wintypes as w
    import time
    if os.name != 'nt':
        raise OSError('Windows named pipes require a Windows client')
    class Overlapped(c.Structure):
        _fields_ = [('internal', c.c_size_t), ('internal_high', c.c_size_t),
                    ('offset', w.DWORD), ('offset_high', w.DWORD), ('event', w.HANDLE)]
    api = c.WinDLL('kernel32', use_last_error=True)
    api.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, c.c_void_p, w.DWORD, w.DWORD, w.HANDLE]
    api.CreateFileW.restype = w.HANDLE
    api.CreateEventW.argtypes = [c.c_void_p, w.BOOL, w.BOOL, w.LPCWSTR]
    api.CreateEventW.restype = w.HANDLE
    api.CloseHandle.argtypes = [w.HANDLE]
    api.WaitNamedPipeW.argtypes = [w.LPCWSTR, w.DWORD]
    api.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
    api.WaitForSingleObject.restype = w.DWORD
    api.CancelIoEx.argtypes = [w.HANDLE, c.POINTER(Overlapped)]
    api.GetOverlappedResult.argtypes = [w.HANDLE, c.POINTER(Overlapped), c.POINTER(w.DWORD), w.BOOL]
    for name in ('ReadFile', 'WriteFile'):
        getattr(api, name).argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.POINTER(Overlapped)]
    deadline = time.monotonic() + 35
    while True:
        handle = api.CreateFileW(str(path), 0xC0000000, 0, None, 3, 0x40110000, None)
        if handle != c.c_void_p(-1).value:
            break
        error = c.get_last_error()
        if error != 231 or time.monotonic() >= deadline:
            raise c.WinError(error)
        api.WaitNamedPipeW(str(path), 1000)
    try:
        def transfer(buffer, size, writing):
            event = api.CreateEventW(None, True, False, None)
            if not event:
                raise c.WinError(c.get_last_error())
            operation = Overlapped(event=event)
            count = w.DWORD()
            try:
                method = api.WriteFile if writing else api.ReadFile
                if not method(handle, buffer, size, c.byref(count), c.byref(operation)):
                    error = c.get_last_error()
                    if error != 997:
                        raise c.WinError(error)
                    remaining = max(0, int((deadline - time.monotonic()) * 1000))
                    if api.WaitForSingleObject(event, remaining) != 0:
                        api.CancelIoEx(handle, c.byref(operation))
                        api.GetOverlappedResult(handle, c.byref(operation), c.byref(count), True)
                        raise TimeoutError('Turf pipe request timed out')
                    if not api.GetOverlappedResult(handle, c.byref(operation), c.byref(count), False):
                        raise c.WinError(c.get_last_error())
                return count.value
            finally:
                api.CloseHandle(event)
        offset = 0
        while offset < len(payload):
            buffer = c.create_string_buffer(payload[offset:])
            count = transfer(buffer, len(payload) - offset, True)
            if not count:
                raise OSError('Pipe closed during write')
            offset += count
        response = bytearray()
        while len(response) <= 32 * 1024 * 1024 + 1:
            buffer = c.create_string_buffer(65536)
            count = transfer(buffer, len(buffer), False)
            if not count:
                break
            response.extend(buffer.raw[:count])
            if b'\n' in response:
                return bytes(response[:response.index(b'\n') + 1])
        raise RuntimeError('Incomplete or oversized response')
    finally:
        api.CloseHandle(handle)


def request(socket_path, method, params=None):
    message = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    payload = json.dumps(message).encode() + b"\n"
    if str(socket_path).startswith('\\\\.\\pipe\\'):
        line = _pipe_exchange(socket_path, payload)
    else:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(35)
            connection.connect(str(socket_path))
            connection.sendall(payload)
            with connection.makefile("rb") as stream:
                line = stream.readline(32 * 1024 * 1024 + 2)
    if not line.endswith(b"\n") or len(line) > 32 * 1024 * 1024 + 1:
        raise RuntimeError("Incomplete or oversized response")
    response = json.loads(line)
    if response.get("id") != 1 or response.get("jsonrpc") != "2.0":
        raise RuntimeError("Invalid JSON-RPC response")
    if "error" in response:
        raise RuntimeError(json.dumps(response["error"]))
    return response["result"]


def grab(socket_path, source, output, chunk_bytes=256 * 1024):
    """Fetch binary data through the page and stream chunks to an atomic local file."""
    if not isinstance(source, str) or not source:
        raise ValueError("grab requires a nonempty source string")
    if not isinstance(chunk_bytes, int) or not 1 <= chunk_bytes <= 512 * 1024:
        raise ValueError("chunk_bytes must be between 1 and 524288")
    output = Path(output)
    token = "__turfGrab_" + uuid.uuid4().hex
    token_js = json.dumps(token)
    temporary = None
    def evaluate(expression):
        return request(socket_path, "evaluate", {"expression": expression})["value"]
    try:
        prepare = Path(__file__).with_name("grab.js").read_text()
        metadata = evaluate(f"{prepare}({token_js}, {json.dumps(source)})")
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix="." + output.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            for offset in range(0, metadata["bytes"], chunk_bytes):
                expression = f"""(async () => {{
                    const state = window[{token_js}];
                    if (!state?.blob) throw new Error('grab state lost, possibly due to navigation');
                    state.refresh();
                    return await new Promise((resolve, reject) => {{
                        const reader = new FileReader();
                        reader.onload = () => resolve(reader.result.split(',')[1]);
                        reader.onerror = () => reject(reader.error);
                        reader.readAsDataURL(state.blob.slice({offset}, {offset + chunk_bytes}));
                    }});
                }})()"""
                chunk = base64.b64decode(evaluate(expression), validate=True)
                if len(chunk) != min(chunk_bytes, metadata["bytes"] - offset):
                    raise RuntimeError("Unexpected grab chunk length")
                stream.write(chunk)
        os.replace(temporary, output)
        temporary = None
        return {**metadata, "path": str(output)}
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        try:
            evaluate(f"(() => {{ clearTimeout(window[{token_js}]?.timer); delete window[{token_js}]; return true; }})()")
        except (OSError, ValueError, RuntimeError, KeyError):
            pass  # Navigation or shutdown already removes the page state; idle state expires.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("socket", help="Unix socket path or local Windows named pipe")
    parser.add_argument("method", help="info, evaluate, navigate, screenshot, resize, screens, move, click, key, typeText, grab, close")
    parser.add_argument("params", nargs="?", default="{}", help="JSON object")
    parser.add_argument("-o", "--output", type=Path, help="Save screenshot PNG or grabbed binary data")
    args = parser.parse_args()
    try:
        params = json.loads(args.params)
        if not isinstance(params, dict):
            raise ValueError("params must be a JSON object")
        if args.method == "grab":
            if args.output is None:
                raise ValueError("grab requires --output")
            result = grab(args.socket, params.get("source"), args.output)
            print(json.dumps(result, ensure_ascii=False))
            return 0
        if args.output and args.method != "screenshot":
            raise ValueError("--output requires screenshot or grab")
        result = request(args.socket, args.method, params)
        if args.output:
            args.output.write_bytes(base64.b64decode(result["data"], validate=True))
            result = {key: value for key, value in result.items() if key != "data"}
            result["path"] = str(args.output)
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
