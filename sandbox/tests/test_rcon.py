"""The RCON client reads a whole reply: Minecraft splits a reply longer than 4096 characters over several packets, and one read
per command left the rest in the socket, to be taken as the NEXT command's reply (shakeout-fleet-a, 2026-11-12: 'computercraft
dump' passed 4096 bytes at ~130 computers, the newest computer fell off the list, and a new loader 'never appeared')."""
import os
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
import rcon  # noqa: E402


def packet(rid, kind, text):
    body = struct.pack("<ii", rid, kind) + text.encode("utf8") + b"\x00\x00"
    return struct.pack("<i", len(body)) + body


class FakeServer:
    """Answers the way the vanilla server does: a command's reply in 4096-character chunks under the request's id, any other
    request type with one 'Unknown request <hex>' packet under its id. Delivers bytes in small pieces, as TCP may."""

    def __init__(self, replies):
        self.replies = dict(replies)
        self.inbox = b""
        self.outbox = b""

    def sendall(self, data):
        self.inbox += data
        while len(self.inbox) >= 4:
            n = struct.unpack("<i", self.inbox[:4])[0]
            if len(self.inbox) < 4 + n:
                break
            body, self.inbox = self.inbox[4:4 + n], self.inbox[4 + n:]
            rid, kind = struct.unpack("<ii", body[:8])
            text = body[8:-2].decode("utf8")
            if kind == 3:
                self.outbox += packet(rid, 2, "")
            elif kind == 2:
                out = self.replies.get(text, "")
                chunks = [out[i:i + 4096] for i in range(0, len(out), 4096)] or [""]
                for ch in chunks:
                    self.outbox += packet(rid, 0, ch)
            else:
                self.outbox += packet(rid, 0, "Unknown request %x" % kind)

    def recv(self, n):
        n = min(n, 700)
        out, self.outbox = self.outbox[:n], self.outbox[n:]
        return out

    def settimeout(self, t):
        pass

    def close(self):
        pass


def client(replies):
    fake = FakeServer(replies)
    orig = rcon.socket.create_connection
    rcon.socket.create_connection = lambda addr, timeout=None: fake
    try:
        return rcon.Rcon("127.0.0.1", 25575, "pw")
    finally:
        rcon.socket.create_connection = orig


class WholeReply(unittest.TestCase):
    def test_a_reply_over_4096_characters_comes_back_whole(self):
        dump = "\n".join("#%d | Y | 134, 90, -%d" % (i, 2800 + i) for i in range(400))
        self.assertGreater(len(dump), 2 * 4096)          # three packets
        r = client({"computercraft dump": dump})
        self.assertEqual(r.command("computercraft dump"), dump)

    def test_the_next_command_gets_its_own_reply_not_the_rest_of_the_last(self):
        dump = "x" * 9000
        r = client({"computercraft dump": dump, "time query gametime": "The time is 42"})
        r.command("computercraft dump")
        self.assertEqual(r.command("time query gametime"), "The time is 42")

    def test_a_short_and_an_empty_reply_unchanged(self):
        r = client({"list": "There are 0 players", "save-all": ""})
        self.assertEqual(r.command("list"), "There are 0 players")
        self.assertEqual(r.command("save-all"), "")

    def test_a_reply_of_exactly_4096_characters(self):
        r = client({"a": "y" * 4096, "b": "ok"})
        self.assertEqual(r.command("a"), "y" * 4096)
        self.assertEqual(r.command("b"), "ok")


if __name__ == "__main__":
    unittest.main()
