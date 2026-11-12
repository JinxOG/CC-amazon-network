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

    def _write(self, kind, text):
        self._id += 1
        body = struct.pack("<ii", self._id, kind) + text.encode("utf8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(body)) + body)
        return self._id

    def _read(self):
        length = struct.unpack("<i", self._recv_exact(4))[0]
        data = self._recv_exact(length)
        r_id, r_kind = struct.unpack("<ii", data[:8])
        return r_id, r_kind, data[8:-2].decode("utf8", "replace")

    def _send(self, kind, text):
        self._write(kind, text)
        return self._read()

    # Any request type other than 2 (command) and 3 (login) gets ONE "Unknown request" packet under its own id, after every
    # packet of the reply before it: the server answers in order.
    MARKER_KIND = 100

    def command(self, text):
        """The command's WHOLE reply. The server splits a reply longer than 4096 characters over several packets; reading one
        packet left the rest in the socket, read later as the next command's reply (shakeout-fleet-a, 2026-11-12). So a marker
        request follows each command, and every packet up to the marker's answer is gathered; packets with an older id (left
        over from a reply cut short by an error) are dropped."""
        cid = self._write(2, text)
        mid = self._write(self.MARKER_KIND, "")
        parts = []
        while True:
            r_id, _, body = self._read()
            if r_id == mid:
                return "".join(parts)
            if r_id == cid:
                parts.append(body)

    def close(self):
        self.sock.close()
