#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
"""Send one JSON-RPC request to an explicitly named Turf Unix socket."""
import argparse
import base64
import json
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("socket", help="Explicit Unix socket path")
    parser.add_argument("method", help="info, evaluate, navigate, screenshot, resize, close")
    parser.add_argument("params", nargs="?", default="{}", help="JSON object")
    parser.add_argument("-o", "--output", type=Path, help="Save screenshot PNG")
    args = parser.parse_args()
    try:
        params = json.loads(args.params)
        if not isinstance(params, dict):
            raise ValueError("params must be a JSON object")
        if args.output and args.method != "screenshot":
            raise ValueError("--output requires screenshot")
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
