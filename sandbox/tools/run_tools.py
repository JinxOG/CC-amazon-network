"""Runs gate_check.py and ack_loss.py against a sandbox run, through the run's own read-only file server.

usage: python sandbox/tools/run_tools.py <run_dir> <since-iso>
Prints one JSON document: {"gate_check": {...}, "ack_loss": {...}}.

Safety (spec 10.7): the address handed to the tools is always 127.0.0.1 on a port this script just
opened; it refuses to run them against anything else.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    if len(sys.argv) < 3:
        print("usage: run_tools.py <run_dir> <since-iso>", file=sys.stderr)
        return 2
    run_dir, since = sys.argv[1], sys.argv[2]
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    assert base.startswith("http://127.0.0.1:"), "refusing to run the tools against a non-local address"

    server = subprocess.Popen(
        ["node", os.path.join(REPO, "sandbox", "bridge", "fileserver.js"), run_dir, str(port)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
    result = {}
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(base + "/ping", timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)
        else:
            raise RuntimeError("file server did not start")

        env = dict(os.environ, BRIDGE_URL=base, PYTHONIOENCODING="utf-8")
        for tool in ("gate_check", "ack_loss"):
            try:
                p = subprocess.run([sys.executable, os.path.join(REPO, "tools", tool + ".py"), since],
                                   capture_output=True, text=True, timeout=300, env=env, cwd=REPO, encoding="utf-8",
                                   errors="replace")
                result[tool] = {"exit": p.returncode, "output": (p.stdout + p.stderr).strip()}
            except subprocess.TimeoutExpired:
                result[tool] = {"exit": None, "output": "timed out after 300 s"}
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except Exception:
            server.kill()
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
