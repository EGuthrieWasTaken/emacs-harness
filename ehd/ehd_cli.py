#!/usr/bin/env python3
"""ehd-cli -- dumb stdin/stdout bridge to the ehd Unix socket.

Installed inside the container image.  `bin/eh`, running outside the
container (over ssh or docker exec), has no way to reach a Unix socket
that lives in the container's mount namespace, so it pipes one JSON
request line to this program's stdin and reads one JSON response line
back from stdout.  All of the actual dispatching happens in `ehd`; this
program does no work of its own beyond exit-code translation.
"""
import json
import os
import socket
import sys

SOCKET_PATH = os.environ.get("EH_SOCK", "/run/eh/eh.sock")


def main() -> int:
    line = sys.stdin.readline()
    if not line:
        sys.stderr.write("ehd-cli: no request on stdin\n")
        return 2
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)
    except OSError as e:
        sys.stdout.write(json.dumps({
            "ok": False,
            "error": {"message": f"cannot reach ehd at {SOCKET_PATH}: {e}"},
            "exit_code": 5,
        }) + "\n")
        return 5
    with sock:
        sock.sendall(line.encode() if not line.endswith("\n") else line.encode())
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if chunk.endswith(b"\n"):
                break
        resp_line = b"".join(chunks).decode()
    sys.stdout.write(resp_line if resp_line.endswith("\n") else resp_line + "\n")
    try:
        resp = json.loads(resp_line)
        return int(resp.get("exit_code", 0 if resp.get("ok") else 1))
    except Exception:
        return 1


if __name__ == "__main__":
    sys.exit(main())
