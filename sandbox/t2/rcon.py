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
    CHUNK = 4096        # the server cuts a reply into pieces of this many characters

    def _next_for(self, cid):
        """The next packet answering request cid; packets with an older id (left over from a reply cut short) are dropped."""
        while True:
            r_id, _, body = self._read()
            if r_id == cid:
                return body

    def command(self, text):
        """The command's WHOLE reply. The server splits a reply longer than 4096 characters over several packets; reading one
        packet left the rest in the socket, read later as the next command's reply (shakeout-fleet-a, 2026-11-12).

        NEVER two packets in flight: the server's one read takes what has arrived, parses ONE packet and throws the rest away.
        Writing a marker right behind the command lost the marker; the client waited out its timeout, reconnected and sent the
        command again, and a repeated setblock answered 'Could not set the block' (shakeout-fleet-b, diag-floor-cell-a). So the
        marker goes only after the first piece is back (the server has read the command by then), and only when that piece is
        a full 4096 characters, the one case where more can follow."""
        cid = self._write(2, text)
        first = self._next_for(cid)
        if len(first.encode("utf8")) < self.CHUNK:
            return first
        parts = [first]
        mid = self._write(self.MARKER_KIND, "")
        while True:
            r_id, _, body = self._read()
            if r_id == mid:
                return "".join(parts)
            if r_id == cid:
                parts.append(body)

    def close(self):
        self.sock.close()
