"""The T2 scenario runner: the parts that broke in the 6x run (a game-time read with no number in the reply) and the log
line parsing its report depends on."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
import scenario  # noqa: E402


class FakeRaw:
    def __init__(self, replies):
        self.replies = list(replies)
        self._rcon = object()

    def command(self, text):
        r = self.replies.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def ctx_with(raw):
    c = scenario.Ctx.__new__(scenario.Ctx)
    c._raw = raw
    return c


class GameTime(unittest.TestCase):
    def test_a_reply_with_no_number_is_retried(self):
        scenario.time.sleep = lambda s: None
        c = ctx_with(FakeRaw(["", "Unknown or incomplete command", "The time is 12345"]))
        self.assertEqual(c.gametime(), 12345)

    def test_a_dropped_connection_is_retried(self):
        scenario.time.sleep = lambda s: None
        c = ctx_with(FakeRaw([OSError("timed out"), "The time is 99"]))
        self.assertEqual(c.gametime(), 99)

    def test_it_gives_up_after_eight_tries_and_says_what_it_saw(self):
        scenario.time.sleep = lambda s: None
        c = ctx_with(FakeRaw(["nothing"] * 8))
        with self.assertRaises(RuntimeError) as cm:
            c.gametime()
        self.assertIn("nothing", str(cm.exception))


class JobSummary(unittest.TestCase):
    def test_the_ore_in_a_real_sector_line_is_counted(self):
        class Ctx:
            def log_lines(self, substr=""):
                lines = [
                    "2026-10-21T04:37:08.712Z  server#28      INFO   Dispatched job_0206 [MINE] -> node_183 (solo)",
                    "2026-10-21T07:43:00.560Z  server#1585    INFO   Sector (1920,-2624) done by node_183 \u2014 4168 ore mined  [job_0206: 1/3 sectors]",
                    "2026-10-21T07:47:24.559Z  server#1626    INFO   Sector (1984,-2624) done by node_183 \u2014 0 ore mined  [job_0206: 2/3 sectors]",
                ]
                return [l for l in lines if substr in l]
        s = scenario.job_summary(Ctx())
        self.assertEqual(s["ore_from_sector_lines"], 4168)
        self.assertEqual(s["sector_done_lines"], 2)


if __name__ == "__main__":
    unittest.main()
