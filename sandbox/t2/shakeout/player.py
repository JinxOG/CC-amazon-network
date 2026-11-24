"""The shakeout's stand-in player: it removes a turtle copy a crash duplicated.

The user, 2026-11-24: a hard server kill can leave a turtle that was crossing a chunk border in two or three places at once
(T2 payload-h's node_397; payload-i's node_215, in three). Turtles cannot dig turtles, so a player has to pick the extra copy up.
The server names it: "NEEDS HANDS: node_N — duplicate_id: node_N heard at X1,Y1,Z1 and X2,Y2,Z2 ..." (W3, w3-payload-i), parks
every copy and drops the id's ATC bookings. The 24-hour test MODELS A PLAYER: PLAYER_DELAY_S after the alarm this removes every
named copy but the FIRST (the newest seq stream's), then releases the id's hold (RELEASE_TURTLE, as a player would from the dashboard;
the server then unparks the turtle and unbans it at the ATC, W3 6c34062). From then on the fleet must recover by itself -- anything
still stuck counts.

Each fix is two lines of <run>/shakeout/faults.jsonl, fault "player_dup_fix" (an unscheduled id "pNNN"): "start" at the alarm and
"end" when the copy is removed, with ok and why. The report excuses everyone between them (the wait for a player), never after.
The removal and the release are INTERVENTIONS. A later alarm for the same id (copied again by a later crash) is a new fix. Never raises
into the run loop's caller: an error is a note and an "end" line with ok false. Needs the server at 6c34062 or later (the release).
"""
import os
import re

from shakeout import schedule

PLAYER_DELAY_S = 600          # the player's response time after the alarm (the user's ruling: "about 10 minutes")
FAULT = "player_dup_fix"
# every copy named: "heard at X1,Y1,Z1 and X2,Y2,Z2[ and X3,Y3,Z3 ...]" (the first is the newest seq stream's: the one kept)
DUP_RX = re.compile(r"NEEDS HANDS: (node_\d+) \S+ duplicate_id: node_\d+ heard at (-?\d+,-?\d+,-?\d+(?: and -?\d+,-?\d+,-?\d+)+)")
TURTLE_BLOCKS = ("computercraft:turtle_normal", "computercraft:turtle_advanced")


class LogTail:
    """The bridge log text written since the last read (every file under <run>/bridge/logs, each from where it left off)."""

    def __init__(self, run):
        self.dir, self.pos = os.path.join(run or "", "bridge", "logs"), {}

    def read(self):
        out = []
        try:
            names = sorted(n for n in os.listdir(self.dir) if n.endswith(".txt"))
        except OSError:
            return ""
        for n in names:
            p = os.path.join(self.dir, n)
            try:
                size, start = os.path.getsize(p), self.pos.get(p, 0)
                if size < start:
                    start = 0
                if size == start:
                    continue
                with open(p, "rb") as f:
                    f.seek(start)
                    data = f.read(size - start)
                cut = data.rfind(b"\n") + 1
                self.pos[p] = start + cut
                out.append(data[:cut].decode("utf8", "replace"))
            except OSError:
                continue
        return "".join(out)


class Player:
    def __init__(self, ctx, t0):
        self.ctx, self.t0, self.tail = ctx, float(t0), LogTail(getattr(ctx, "run", ""))
        self.pending, self.n = {}, 0      # node -> {"id", "seen", "cells"}

    def _wall(self, now):
        return int((now - self.t0) * 1000)

    def _log(self, now, fid, phase, **detail):
        schedule._log(self.ctx, self._wall(now), {"id": fid, "fault": FAULT}, phase, **detail)

    def _has_turtle(self, cell):
        x, y, z = cell
        return any("Test passed" in (self.ctx._raw.command("execute if block %d %d %d %s" % (x, y, z, kind)) or "")
                   for kind in TURTLE_BLOCKS)

    def tick(self, now):
        for m in DUP_RX.finditer(self.tail.read()):
            node = m.group(1)
            if node in self.pending:
                continue                      # the server repeats its alarm: one fix at a time per id
            self.n += 1
            fid = "p%03d" % self.n
            cells = [tuple(int(v) for v in c.split(",")) for c in m.group(2).split(" and ")]
            self.pending[node] = {"id": fid, "seen": now, "cells": cells}
            self._log(now, fid, "start", node=node, cells=cells, delay_s=PLAYER_DELAY_S)
        for node, p in list(self.pending.items()):
            if now - p["seen"] < PLAYER_DELAY_S:
                continue
            del self.pending[node]
            try:
                extra = [c for c in p["cells"][1:] if self._has_turtle(c)]
                if not extra:
                    self._log(now, p["id"], "end", node=node, ok=False,
                              why="no turtle at any cell named but the kept one: %s" % p["cells"])
                    continue
                for cell in extra:
                    cmd = "setblock %d %d %d minecraft:air" % cell
                    schedule._intervention(self.ctx, p["id"], "command", cmd)
                    self.ctx._raw.command(cmd)
                left = [list(c) for c in extra if self._has_turtle(c)]
                released = None
                if not left:
                    schedule._intervention(self.ctx, p["id"], "dispatch", "RELEASE_TURTLE", {"turtleId": node})
                    released = self.ctx.dispatch("RELEASE_TURTLE", {"turtleId": node})
                self._log(now, p["id"], "end", node=node, removed=[list(c) for c in extra], kept=list(p["cells"][0]),
                          ok=not left, released=repr(released)[:80],
                          why="copies removed, hold released" if not left else "copies still there after setblock: %s" % left)
            except Exception as ex:  # noqa: BLE001 - never the end of a 24-hour run
                if hasattr(self.ctx, "note"):
                    self.ctx.note("player: %s fix failed: %s: %s" % (node, type(ex).__name__, ex))
                self._log(now, p["id"], "end", node=node, ok=False, why="%s: %s" % (type(ex).__name__, ex))
