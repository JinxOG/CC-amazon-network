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


class DispatchSpacing(unittest.TestCase):
    """central_server drops a bridge command whose (bridge ms stamp, type) it has seen: 126 HOLD_TURTLEs posted back to back
    lost 29 as 'duplicate ignored' (shakeout-fleet-d, 2026-11-12). No two posts may reach the bridge in one millisecond."""

    def test_back_to_back_posts_are_at_least_two_ms_apart(self):
        clock = [1000.0]
        sent = []
        orig = (scenario.time.monotonic, scenario.time.sleep, scenario.runmod.bridge_post)
        scenario.time.monotonic = lambda: clock[0]
        scenario.time.sleep = lambda s: clock.__setitem__(0, clock[0] + s)
        scenario.runmod.bridge_post = lambda path, obj: sent.append(clock[0]) or "{}"
        try:
            c = scenario.Ctx.__new__(scenario.Ctx)
            c.notes, c.g0 = [], None
            for _ in range(5):
                c.dispatch("HOLD_TURTLE", {"turtleId": "node_1"})
        finally:
            scenario.time.monotonic, scenario.time.sleep, scenario.runmod.bridge_post = orig
        self.assertEqual(len(sent), 5)
        self.assertTrue(all(b - a >= 0.002 for a, b in zip(sent, sent[1:])), sent)


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


class FakeControl:
    def __init__(self):
        self.sent = []

    def command(self, text):
        self.sent.append(text)
        return "ok"


def recording_ctx():
    c = scenario.Ctx.__new__(scenario.Ctx)
    c.interventions = []
    c.g0 = None
    c._c = FakeControl()
    c.control = scenario.Interventions(c, c._c)
    return c


class ConsoleCommandsAreInterventions(unittest.TestCase):
    """The report's INTERVENTIONS must list a raw console command that changes the world (W1's card): `command` used to be a read for every text, so a run that
    used fill, setblock and forceload still said nobody had reached into it. Reads must stay out."""
    CHANGES = ["fill 1 2 3 4 5 6 stone", "setblock 1 2 3 stone", "/setblock 1 2 3 air", "clone 1 2 3 4 5 6 7 8 9 replace move", "forceload add 10 10",
               "forceload remove 10 10", "data modify block 1 2 3 Fuel set value 5", "data merge block 1 2 3 {}", "data remove block 1 2 3 x",
               "summon minecraft:pig", "kill @e", "give @p stone", "time set day", "gamerule doDaylightCycle false", "tp @p 0 0 0", "teleport @p 0 0 0",
               "computercraft shutdown #5", "computercraft turn-on #5", "execute in minecraft:overworld run setblock 1 2 3 stone", "t2 radio loss 0.5 10"]
    READS = ["data get block 1 2 3 Fuel", "time query gametime", "forceload query 1 2", "computercraft dump", "execute if block 1 2 3 air", "list",
             "forge tps", "gamerule doDaylightCycle", "t2 status", "t2 chunk list", "say hello", "execute if loaded 1 70 1 run say hi"]

    def test_every_world_changing_command_is_recorded(self):
        for text in self.CHANGES:
            c = recording_ctx()
            c.control.command(text)
            self.assertEqual([i["verb"] for i in c.interventions], ["command"], text)
            self.assertIn(text, c.interventions[0]["args"][0])
            self.assertEqual(c._c.sent, [text], "the command is still sent")

    def test_a_read_only_probe_records_nothing(self):
        for text in self.READS:
            c = recording_ctx()
            c.control.command(text)
            self.assertEqual(c.interventions, [], text)
            self.assertEqual(c._c.sent, [text])

    def test_the_run_report_no_longer_says_nobody_reached_in_after_a_fill(self):
        c = recording_ctx()
        c.control.command("data get block 1 2 3 Items")
        c.control.command("fill 0 0 0 1 1 1 air")
        c.control.command("forceload add 5 5")
        self.assertEqual([i["args"][0] for i in c.interventions], ["'fill 0 0 0 1 1 1 air'", "'forceload add 5 5'"])


if __name__ == "__main__":
    unittest.main()
