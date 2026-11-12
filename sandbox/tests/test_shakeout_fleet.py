"""Shakeout Task 5: fleet placement (sandbox/t2/shakeout/fleet.py). The REAL Control verbs (spawn_turtle, set_slot,
clear_slot, shutdown, turn_on) run against a fake game that keeps blocks, computers and turtle inventories and answers rcon
the way Minecraft 1.20.1 and CC:Tweaked do; the seeded dock_assignments.dat is read back by the REAL waypoints.lua.

    python -I sandbox/tests/test_shakeout_fleet.py
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
from shakeout import fleet, world  # noqa: E402
import control  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
COORD = r"(-?\d+) (-?\d+) (-?\d+)"
CELLS = world.dock_cells()
SERVER_POS = (136, 67, -2802)
STATE_FILES = ("journal.dat", "journal.tmp", "gps_home.dat", "crash.log", "loader_state.dat", "update_ref.txt", "scanner_state.dat")


class FakeGame:
    """Blocks by position; a CC block is {"cid", "on", "items": {slot: text}, "fuel", "right", "facing"}."""

    def __init__(self, disks):
        self.disks = disks
        self.blocks = {}
        self.next_id = 198                      # ids.json in the 2026-10-18 copy says 198 was the last
        self.sent = []
        self.events = []
        self.blocks[SERVER_POS] = {"kind": "computercraft:computer_advanced", "cid": 95, "on": True, "items": {}}

    def comp_at(self, pos):
        b = self.blocks.get(pos)
        return b if b and b.get("cid") is not None else None

    def command(self, text):
        self.sent.append(text)
        if text == "computercraft dump":
            return "\n".join("#%d | %s | %d, %d, %d" % ((b["cid"], "Y" if b["on"] else "N") + p)
                             for p, b in sorted(self.blocks.items()) if b.get("cid") is not None)
        m = re.match(r"^computercraft (shutdown|turn-on) #(\d+)$", text)
        if m:
            cid = int(m.group(2))
            for p, b in self.blocks.items():
                if b.get("cid") == cid:
                    b["on"] = m.group(1) == "turn-on"
                    self.events.append((m.group(1), cid, os.path.exists(os.path.join(self.disks, "95", "dock_assignments.dat"))))
                    return "1 computer(s)"
            return "No computers matched"
        m = re.match(r"^execute if block %s (\S+)$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            b = self.blocks.get(pos)
            want = m.group(4)
            if want in ("minecraft:air", "minecraft:cave_air"):
                return "Test passed" if b is None and want == "minecraft:air" else "Test failed"
            return "Test passed" if b and want.split("[")[0] == b["kind"] and ("[" not in want or b.get("facing") in want) else "Test failed"
        m = re.match(r"^setblock %s (\S+?)(\[[^\]]*\])?(\{.*\})?$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            kind, props, nbt = m.group(4), m.group(5) or "", m.group(6) or ""
            if kind == "minecraft:air":
                if pos not in self.blocks:
                    return "Could not set the block"
                del self.blocks[pos]
                return "Changed the block at %d, %d, %d" % pos
            if pos in self.blocks:
                raise AssertionError("setblock onto an occupied cell %s" % (pos,))
            self.next_id += 1
            right = re.search(r'RightUpgrade:"([^"]+)"', nbt)
            fuel = re.search(r"Fuel:(\d+)", nbt)
            self.blocks[pos] = {"kind": kind, "cid": self.next_id, "on": "On:1b" in nbt, "items": {},
                                "right": right.group(1) if right else None, "fuel": int(fuel.group(1)) if fuel else 0,
                                "facing": re.search(r"facing=(\w+)", props).group(1) if "facing" in props else None,
                                "nbt": nbt}
            return "Changed the block at %d, %d, %d" % pos
        m = re.match(r"^data get block %s Items\[\{Slot:(\d+)b\}\]$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            slot = int(m.group(4))
            item = self.comp_at(pos)["items"].get(slot)
            if item is None:
                return "Found no elements matching Items[{Slot:%db}]" % slot
            return "%d, %d, %d has the following block data: %s" % (pos + (item,))
        m = re.match(r"^data get block %s$" % COORD, text)       # the whole block: a world-copy turtle has an Owner
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            return '%d, %d, %d has the following block data: {Owner: {UpperId: -47L, LowerId: -81L, Name: "HighJinxOG"}, ComputerId: %d}' % (
                pos + (self.comp_at(pos)["cid"],))
        m = re.match(r"^data get block %s (Fuel|RightUpgrade|LeftUpgrade)$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            b = self.comp_at(pos)
            v = {"Fuel": b["fuel"], "RightUpgrade": '"%s"' % b["right"], "LeftUpgrade": '"computercraft:wireless_modem_advanced"'}[m.group(4)]
            return "%d, %d, %d has the following block data: %s" % (pos + (v,))
        m = re.match(r"^data modify block %s Items append value \{Slot:(\d+)b,id:\"([^\"]+)\",Count:(\d+)b(?:,tag:(.*))?\}$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            slot, item, count, tag = int(m.group(4)), m.group(5), int(m.group(6)), m.group(7)
            self.comp_at(pos)["items"][slot] = '{Slot: %db, id: "%s", Count: %db%s}' % (slot, item, count, (", tag: " + tag) if tag else "")
            return "Modified block data of %d, %d, %d" % pos
        m = re.match(r"^data modify block %s Items\[\{Slot:(\d+)b\}\] set value .*minecraft:air.*$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            self.comp_at(pos)["items"].pop(int(m.group(4)), None)
            return "Modified block data of %d, %d, %d" % pos
        raise AssertionError("the fake game does not know %r" % text)


class GameControl(control.Control):
    """The real Control; only its rcon is the fake game, and its disk root is a temp folder."""

    def __init__(self, game, disks):
        self.game, self.disks = game, disks
        self.run = os.path.dirname(disks)
        self.world = self.run
        self._rcon, self._gps_hosts_down, self._scheduled, self._listener, self._harvested = game, None, [], None, {}

    def rcon(self):
        return self.game


class FakeCtx:
    def __init__(self):
        self.run = tempfile.mkdtemp(prefix="shakeout_fleet_test")
        disks = os.path.join(self.run, "disks")
        os.makedirs(disks)
        self.game = FakeGame(disks)
        self.control = self._raw = GameControl(self.game, disks)
        self.interventions = []
        self.notes = []
        self.pin = None
        self.rate = 20
        self.samples = []
        self.g0 = None
        write_disk(disks, 95, {"role.txt": "SERVER", "startup.lua": "-- central_server.lua\n", "jobs.dat": "{}",
                               "dock_assignments.dat": '{ DELIVERY = { "node_96" } }'})
        write_disk(disks, 96, dict({"role.txt": "DELIVERY", ".role": "delivery", "startup.lua": "-- delivery_turtle.lua\n",
                                    "turtle_base.lua": "-- base\n", "protocol.lua": "-- proto\n"}, **{s: "state" for s in STATE_FILES}))
        write_disk(disks, 143, dict({"role.txt": "SUPPORT", ".role": "support", "startup.lua": "-- support_turtle.lua\n",
                                     "turtle_base.lua": "-- base\n"}, **{s: "state" for s in STATE_FILES}))
        write_disk(disks, 183, dict({"role.txt": "MINER", ".role": "miner", "startup.lua": "-- ore_turtle.lua\n",
                                     "mine_flow.lua": "-- mine\n", "equipment.lua": "-- eq\n"}, **{s: "state" for s in STATE_FILES}))
        write_disk(disks, 195, {"role.txt": "LOADER", ".role": "loader", "startup.lua": "-- loader_turtle.lua\n",
                                "protocol.lua": "-- proto\n", "install": "-- installer\n", "loader_beacon.log": "old beacons\n"})

    def note(self, text):
        self.notes.append(text)

    def log_lines(self, substr=""):
        line = "2026-11-10T00:00:00Z  server#1  INFO   Central server online (v1.9.200) ID: node_95"
        return [line] if substr in line else []


def write_disk(disks, cid, files):
    d = os.path.join(disks, str(cid))
    os.makedirs(d, exist_ok=True)
    for name, text in files.items():
        with open(os.path.join(d, name), "w", newline="\n") as f:
            f.write(text)


DONORS = {"DELIVERY": 96, "SUPPORT": 143, "MINER": 183}


def place(ctx, layout=None):
    real_sleep = control.time.sleep
    control.time.sleep = lambda s: None
    try:
        return fleet.place_fleet(ctx, layout or CELLS, donors=DONORS, loader_donor=195)
    finally:
        control.time.sleep = real_sleep


def dock_of_each(dat_path, nodes, infos=None):
    """What the REAL waypoints.lua makes of the seeded file: {node: (type, x, z)} and its warnings (its INFO lines go into
    `infos` when a list is given)."""
    d = tempfile.mkdtemp(prefix="shakeout_dock_read")
    with open(os.path.join(d, "ids.txt"), "w") as f:
        f.write("\n".join(nodes) + "\n")
    lua = os.path.join(d, "read.lua")
    with open(lua, "w") as f:
        f.write(r'''
local wp, dat, ids = arg[1], arg[2], arg[3]
local function real(p) if p == "dock_assignments.dat" then return dat end return p end
fs = { exists = function(p) local f = io.open(real(p), "r"); if f then f:close(); return true end; return false end,
       open = function(p, m) local f = io.open(real(p), (m == "w") and "w" or "r"); if not f then return nil end
         return { readAll = function() return f:read("*a") end, write = function(s) f:write(s) end, close = function() f:close() end } end }
textutils = { unserialise = function(s) local fn = load("return " .. s, "unserialise", "t", {}); if not fn then return nil end
  local ok, v = pcall(fn); if ok then return v end; return nil end }
local W = dofile(wp)
W.loadDockAssignments(function(m) print("INFO " .. m) end, function(m) print("WARN " .. m) end)
for id in io.lines(ids) do
  local t, dk = W.dockOf(id)
  if dk then print(string.format("DOCK %s %s %d %d", id, t, dk.x, dk.z)) else print("NODOCK " .. id) end
end
''')
    p = subprocess.run([world.lua_interpreter(), lua, os.path.join(REPO, "waypoints.lua"), dat_path, os.path.join(d, "ids.txt")],
                       capture_output=True, check=True)
    out, warns = {}, []
    for line in p.stdout.decode().splitlines():
        if line.startswith("DOCK "):
            _, node, t, x, z = line.split()
            out[node] = (t, int(x), int(z))
        elif line.startswith("WARN "):
            warns.append(line)
        elif line.startswith("INFO ") and infos is not None:
            infos.append(line)
    return out, warns


def mismatches(placed, docks):
    return sorted(n for n, cell in placed.items() if docks.get(n) != (cell["type"], cell["x"], cell["z"]))


class TheFleet(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ctx = FakeCtx()
        cls.placed = place(cls.ctx)
        cls.disks = cls.ctx.control.disks
        cls.game = cls.ctx.game

    def turtle_at(self, cell):
        return self.game.blocks.get((cell["x"], cell["y"], cell["z"]))

    def test_every_placed_turtle_carries_the_world_copy_owner(self):
        """A turtle set by setblock has no Owner, and CC places blocks with a fake player made from it: an ownerless turtle
        cannot turtle.place anything (T2 run shakeout-ender-e), so every place_fleet turtle must be given the Owner."""
        for node, cell in self.placed.items():
            self.assertIn('Owner:{UpperId:-47L,LowerId:-81L,Name:"HighJinxOG"}', self.turtle_at(cell)["nbt"], node)

    def test_fleet_is_fresh(self):
        placed, game = self.placed, self.game
        self.assertEqual(len(placed), 160)
        ids = [int(n.replace("node_", "")) for n in placed]
        self.assertEqual(len(set(ids)), 160, "160 distinct computer ids")
        self.assertFalse(set(ids) & {95, 96, 143, 183, 195}, "no id of the world copy's own computers")
        counts = {}
        for n, cell in placed.items():
            counts[cell["type"]] = counts.get(cell["type"], 0) + 1
            b = self.turtle_at(cell)
            self.assertEqual(b["cid"], int(n.replace("node_", "")), "%s stands in its cell" % n)
            self.assertEqual(b["facing"], cell["facing"])
            self.assertTrue(b["on"])
            kit = fleet.ROLE_KIT[cell["type"]]
            self.assertEqual(b["right"], kit["right"])
            self.assertEqual(b["fuel"], kit["fuel"])
            self.assertNotIn("uuid", b["nbt"], "no copied chunky identity on the turtle itself")
            files = os.listdir(os.path.join(self.disks, n.replace("node_", "")))
            self.assertEqual([f for f in files if fleet.is_state_file(f)], [], "%s's disk has no state files: %s" % (n, files))
            self.assertEqual(sorted(set(files) & set(STATE_FILES)), [], "none of the donor's journals, logs or saves: %s" % files)
            self.assertFalse([f for f in files if f.endswith((".dat", ".log", ".tmp"))], files)
            self.assertIn("startup.lua", files)
        self.assertEqual(counts, {"DELIVERY": 16, "SUPPORT": 16, "MINER": 128})

    def test_every_loader_is_its_own_fresh_turtle(self):
        loaders = []
        fleet_ids = {int(n.replace("node_", "")) for n in self.placed}
        for n, cell in self.placed.items():
            items = self.turtle_at(cell)["items"]
            kit = fleet.ROLE_KIT[cell["type"]]
            for slot, (item, count, tag) in kit["items"].items():
                self.assertIn('id: "%s"' % item, items.get(slot, ""), "%s slot %d" % (n, slot))
                if tag and slot != kit.get("loader_slot"):
                    self.assertIn("tag: " + tag, items[slot], "%s slot %d keeps its NBT" % (n, slot))
            self.assertEqual(sorted(items), sorted(kit["items"]))
            if cell["type"] != "MINER":
                continue
            text = items[kit["loader_slot"]]
            self.assertNotIn("uuid", text, "%s's loader carries no copied chunky UUID" % n)
            m = re.search(r"ComputerId:(\d+)", text)
            self.assertIsNotNone(m, text)
            lid = int(m.group(1))
            self.assertIn('loader_%d' % lid, text, "labelled after its own id, as the world's loaders are")
            loaders.append(lid)
            files = os.listdir(os.path.join(self.disks, str(lid)))
            self.assertIn("startup.lua", files)
            self.assertEqual([f for f in files if fleet.is_state_file(f)], [], "loader %d disk: %s" % (lid, files))
            with open(os.path.join(self.disks, str(lid), "role.txt")) as f:
                self.assertEqual(f.read().strip(), "LOADER")
        self.assertEqual(len(loaders), 128)
        self.assertEqual(len(set(loaders)), 128, "every loader has its own computer id")
        self.assertFalse(set(loaders) & (fleet_ids | {195}), "no loader shares an id with a turtle or the donor loader")
        staged = [p for p, b in self.game.blocks.items() if b.get("cid") in set(loaders)]
        self.assertEqual(staged, [], "no loader is left standing at the staging spot")

    def test_seeded_docks_match_positions(self):
        dat = os.path.join(self.disks, "95", "dock_assignments.dat")
        infos = []
        docks, warns = dock_of_each(dat, sorted(self.placed), infos)
        self.assertEqual(warns, [])
        self.assertEqual(mismatches(self.placed, docks), [])
        # final review I2: the seed is the new saver's format, so it is read BY POSITION (its legacy lists agree with byPos);
        # a seed in any other shape is read from the lists, which this line would name
        self.assertEqual(infos, [], "the seed is read by position, silently")
        with open(dat) as f:
            data = f.read()
        self.assertNotIn("MINER =", data, "no MINER list: an older server has no use for one")
        for n, cell in self.placed.items():
            b = self.turtle_at(cell)
            self.assertEqual(b["cid"], int(n.replace("node_", "")), "the turtle stands on the dock the file gives it")
        server = [e for e in self.game.events if e[1] == 95]
        self.assertEqual(server[0][0], "shutdown", "the dispatch computer goes off before the fleet is placed")
        self.assertEqual(server[-1], ("turn-on", 95, True), "and comes back only once the file is written")
        first_turtle = next(i for i, t in enumerate(self.game.sent) if t.startswith("setblock") and "turtle_advanced" in t)
        off = next(i for i, t in enumerate(self.game.sent) if t == "computercraft shutdown #95")
        self.assertLess(off, first_turtle)

    def test_the_seed_check_can_fail(self):
        """The same read-back judges a corrupted file wrong: two entries swapped, and one dropped."""
        dat = os.path.join(self.disks, "95", "dock_assignments.dat")
        with open(dat) as f:
            text = f.read()
        nodes = sorted(self.placed)
        a, b = nodes[0], nodes[1]
        bad = text.replace('"%s"' % a, '"@@"').replace('"%s"' % b, '"%s"' % a).replace('"@@"', '"%s"' % b)
        bad = re.sub(r'\[ [^\]]+ \] = "%s",?' % nodes[2], "", bad)       # from byPos AND from its legacy list
        path = os.path.join(tempfile.mkdtemp(), "dock_assignments.dat")
        with open(path, "w") as f:
            f.write(bad)
        docks, _ = dock_of_each(path, nodes)
        self.assertEqual(mismatches(self.placed, docks), sorted([a, b, nodes[2]]))

    def test_the_seed_is_by_position_and_names_only_the_new_fleet(self):
        with open(os.path.join(self.disks, "95", "dock_assignments.dat")) as f:
            text = f.read()
        self.assertIn("byPos", text)
        self.assertNotIn("node_96", text, "the world copy's old assignments are gone")
        self.assertEqual(len(re.findall(r'\[ "-?\d+,-?\d+" \] = "node_\d+"', text)), 160)

    def test_every_placement_is_an_intervention(self):
        verbs = [i["verb"] for i in self.ctx.interventions]
        self.assertIn("write_disk", verbs)
        self.assertGreaterEqual(verbs.count("write_disk"), 1 + 128, "the dock file and each loader's code")


class PlacementRefuses(unittest.TestCase):
    def test_an_occupied_dock_cell_stops_the_placement(self):
        ctx = FakeCtx()
        c = CELLS[5]
        ctx.game.blocks[(c["x"], c["y"], c["z"])] = {"kind": "computercraft:turtle_advanced", "cid": 96, "on": True, "items": {}}
        with self.assertRaises(RuntimeError) as cm:
            place(ctx)
        self.assertIn("%d,%d,%d" % (c["x"], c["y"], c["z"]), str(cm.exception))
        self.assertFalse(any(t.startswith("setblock") for t in ctx.game.sent), "nothing is placed")


class BootingGame(FakeGame):
    """A turtle that, once on, writes its own boot log (as logship would): a fresh turtle doing that is not stale."""

    def command(self, text):
        out = super().command(text)
        m = re.match(r"^computercraft turn-on #(\d+)$", text)
        if m and int(m.group(1)) != 95:
            d = os.path.join(self.disks, m.group(1))
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "boot.log"), "w") as f:
                f.write("booted\n")
        return out


class BreakingGame(FakeGame):
    """Refuses the setblock of the fifth fleet turtle: a placement that stops part-way."""

    turtles = 0

    def command(self, text):
        if text.startswith("setblock") and "turtle_advanced" in text and "On:1b" not in text:
            self.turtles += 1
            if self.turtles == 5:
                return "Could not set the block (fake)"
        return super().command(text)


class PlacementRobustness(unittest.TestCase):
    def ctx_with(self, game_cls):
        ctx = FakeCtx()
        ctx.game = game_cls(ctx.control.disks)
        ctx.control.game = ctx.control._rcon = ctx.game
        return ctx

    def test_a_turtles_own_boot_log_does_not_stop_the_placement(self):
        ctx = self.ctx_with(BootingGame)
        placed = place(ctx, CELLS[:20])
        self.assertEqual(len(placed), 20)
        some = next(iter(placed)).replace("node_", "")
        self.assertIn("boot.log", os.listdir(os.path.join(ctx.control.disks, some)), "it did boot and write its log")

    def test_a_placement_that_stops_part_way_turns_the_server_back_on_with_what_was_placed(self):
        ctx = self.ctx_with(BreakingGame)
        with self.assertRaises(RuntimeError):
            place(ctx, CELLS[:20])
        server = [e for e in ctx.game.events if e[1] == 95]
        self.assertEqual(server[-1], ("turn-on", 95, True), "the dispatch computer is back on, with a seed written")
        dat = os.path.join(ctx.control.disks, "95", "dock_assignments.dat")
        placed = ctx.shakeout_fleet["placed"]
        self.assertEqual(len(placed), 4)
        self.assertFalse(ctx.shakeout_fleet["complete"])
        docks, warns = dock_of_each(dat, sorted(placed))
        self.assertEqual(mismatches(placed, docks), [], "the four placed turtles are seeded where they stand")


class Strays(unittest.TestCase):
    def test_a_fleet_turtle_outside_the_docks_is_retired_and_a_roleless_body_is_not(self):
        ctx = FakeCtx()
        g = ctx.game
        write_disk(ctx.control.disks, 178, {"role.txt": "MINER", "startup.lua": "-- ore_turtle.lua\n"})
        g.blocks[(839, 200, -2813)] = {"kind": "computercraft:turtle_advanced", "cid": 178, "on": True, "items": {}}
        g.blocks[(164, 67, -2812)] = {"kind": "computercraft:turtle_advanced", "cid": 130, "on": False, "items": {}}
        g.blocks[(160, 67, -2786)] = {"kind": "computercraft:computer_advanced", "cid": 300, "on": True, "items": {}}
        write_disk(ctx.control.disks, 300, {"role.txt": "atc"})
        out = fleet.retire_strays(ctx, keep=[95])
        self.assertEqual(out, [(178, (839, 200, -2813), "MINER")])
        self.assertNotIn((839, 200, -2813), g.blocks)
        self.assertIn((164, 67, -2812), g.blocks, "a turtle with no role is not a fleet node")
        self.assertIn((160, 67, -2786), g.blocks, "the ATC is not a fleet turtle")
        self.assertTrue(os.path.exists(os.path.join(ctx.control.disks, "178", "startup.lua")), "its disk (code) stays")


class TheKit(unittest.TestCase):
    def test_strip_identity(self):
        tag = ('{LeftUpgrade:"computercraft:wireless_modem_advanced",RightUpgradeNbt:{uuid:[I;1,2,3,4]},ComputerId:195,'
               'display:{Name:\'{"text":"loader_195"}\'},RightUpgrade:"advancedperipherals:chunky_turtle"}')
        out = fleet.strip_identity(tag)
        self.assertNotIn("uuid", out)
        self.assertNotIn("ComputerId", out)
        self.assertNotIn("loader_195", out)
        self.assertIn('RightUpgrade:"advancedperipherals:chunky_turtle"', out)

    def test_role_kit_read_from_the_game_matches_and_a_change_is_seen(self):
        ctx = FakeCtx()
        g = ctx.game
        for role, cid, pos in (("DELIVERY", 96, (153, 67, -2806)), ("SUPPORT", 143, (156, 67, -2793)), ("MINER", 183, (167, 67, -2806))):
            kit = fleet.ROLE_KIT[role]
            items = {}
            for slot, (item, count, tag) in kit["items"].items():
                if slot == kit.get("loader_slot"):
                    tag = tag[:-1] + ',RightUpgradeNbt:{uuid:[I;9,9,9,9]},ComputerId:195,display:{Name:\'{"text":"loader_195"}\'}}'
                items[slot] = '{Slot: %db, id: "%s", Count: %db%s}' % (slot, item, count, (", tag: " + tag) if tag else "")
            g.blocks[pos] = {"kind": "computercraft:turtle_advanced", "cid": cid, "on": True, "items": items, "fuel": kit["fuel"],
                             "right": kit["right"]}
        read = fleet.read_role_kit(ctx, {"DELIVERY": 96, "SUPPORT": 143, "MINER": 183})
        self.assertEqual(fleet.kit_differences(fleet.ROLE_KIT, read), [])
        g.blocks[(167, 67, -2806)]["items"][15] = '{Slot: 15b, id: "enderstorage:ender_chest", Count: 1b, tag: {Frequency: {left: 0, middle: 2, right: 0}}}'
        read = fleet.read_role_kit(ctx, {"DELIVERY": 96, "SUPPORT": 143, "MINER": 183})
        diffs = fleet.kit_differences(fleet.ROLE_KIT, read)
        self.assertEqual(len(diffs), 1, diffs)
        self.assertIn("MINER slot 15", diffs[0])


if __name__ == "__main__":
    unittest.main()
