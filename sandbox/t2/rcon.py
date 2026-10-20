"""Minimal Minecraft RCON client (the protocol is public: wiki.vg/RCON). Local use only."""
import socket
import struct


class Rcon:
    def __init__(self, host, port, password, timeout=10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self._id = 0
        r_id, _, _ = self._send(3, password)
        if r_id == -1:
            raise RuntimeError("rcon: wrong password")

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("rcon: connection closed")
            buf += chunk
        return buf

    def _send(self, kind, text):
        self._id += 1
        body = struct.pack("<ii", self._id, kind) + text.encode("utf8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(body)) + body)
        length = struct.unpack("<i", self._recv_exact(4))[0]
        data = self._recv_exact(length)
        r_id, r_kind = struct.unpack("<ii", data[:8])
        return r_id, r_kind, data[8:-2].decode("utf8", "replace")

    def command(self, text):
        return self._send(2, text)[2]

    def close(self):
        self.sock.close()
