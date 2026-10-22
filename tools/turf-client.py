#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Send one JSON-RPC request to an explicitly named Turf Unix socket."""
import argparse
import base64
import json
import os
import tempfile
import uuid
import socket
import sys
from pathlib import Path


def request(socket_path, method, params=None):
    message = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(35)
        connection.connect(str(socket_path))
        connection.sendall(json.dumps(message).encode() + b"\n")
        with connection.makefile("rb") as stream:
            line = stream.readline(32 * 1024 * 1024 + 2)
    if not line.endswith(b"\n"):
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
    parser.add_argument("socket", help="Explicit Unix socket path")
    parser.add_argument("method", help="info, evaluate, navigate, screenshot, resize, click, key, typeText, grab, close")
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
