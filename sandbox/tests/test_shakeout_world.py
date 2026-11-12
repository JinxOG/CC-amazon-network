"""Shakeout Task 4: the world builder (sandbox/t2/shakeout/world.py), against a fake server that keeps blocks and answers rcon the
way Minecraft 1.20.1 does (`execute if block`, `data get block`, `setblock`, `forceload`). Nothing here talks to a real server."""
import os
import re
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
from shakeout import world  # noqa: E402
import control  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
COORD = r"(-?\d+) (-?\d+) (-?\d+)"
CHEST_DEFAULT = "rot: 0b, keepPacked: 0b, Frequency: {left: 0, middle: 0, right: 0}"
CC_BLOCKS = ("computercraft:turtle_advanced", "computercraft:turtle_normal", "computercraft:computer_advanced")
BE_BLOCKS = ("enderstorage:ender_chest",) + CC_BLOCKS


def split_spec(spec):
    """'id[a=b]{nbt}' -> (id, {a: b}, nbt text or None)."""
    m = re.match(r"^([a-z0-9_:.#-]+)(\[[^\]]*\])?(\{.*\})?$", spec.strip())
    if not m:
        raise ValueError("bad block spec %r" % spec)
    props = {}
    if m.group(2):
        for kv in m.group(2)[1:-1].split(","):
            if kv.strip():
                k, v = kv.split("=")
                props[k.strip()] = v.strip()
    return m.group(1), props, m.group(3)


class FakeServer:
    """Blocks by position: (id, props, nbt inner text or None, computer id or None). Everything unset is air."""

    def __init__(self):
        self.blocks = {}
        self.sent = []
        self.forced = set()
        self.spawned = []
        self.saved = []
        self.next_id = 500

    # -- seeding -------------------------------------------------------------------------------------------
    def put(self, pos, spec, cid=None):
        bid, props, nbt = split_spec(spec)
        self.blocks[tuple(pos)] = (bid, props, nbt[1:-1] if nbt else None, cid)

    def at(self, pos):
        return self.blocks.get(tuple(pos), ("minecraft:air", {}, None, None))

    # -- the Control surface build_world uses -------------------------------------------------------------
    def command(self, text):
        self.sent.append(text)
        m = re.match(r"^execute if block %s (.+)$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            bid, props, nbt = split_spec(m.group(4))
            have = self.at(pos)
            ok = have[0] == bid and all(have[1].get(k, self.default_prop(have[0], k)) == v for k, v in props.items())
            return "Test passed" if ok else "Test failed"
        m = re.match(r"^data get block %s\s*(.*)$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            bid, _, nbt, cid = self.at(pos)
            if bid not in BE_BLOCKS:
                return "The target block is not a block entity"
            inner = ("ComputerId: %d, " % cid if cid is not None else "") + (nbt or "")
            return "%d, %d, %d has the following block data: {x: %d, y: %d, z: %d, id: \"%s\", %s}" % (
                pos + pos + (bid, inner.strip(", ")))
        m = re.match(r"^setblock %s (.+)$" % COORD, text)
        if m:
            pos = tuple(int(m.group(i)) for i in (1, 2, 3))
            bid, props, nbt = split_spec(m.group(4))
            have = self.at(pos)
            if have[0] == bid and have[1] == props:
                return "Could not set the block"          # vanilla: same state, nothing changes, the NBT is NOT applied
            if bid == "minecraft:air":
                self.blocks.pop(pos, None)
            elif bid == "enderstorage:ender_chest" and not nbt:
                self.blocks[pos] = (bid, props, CHEST_DEFAULT, None)          # the game's defaults: what a chest WITHOUT NBT shows
            else:
                self.blocks[pos] = (bid, props, (nbt[1:-1] if nbt else "") if bid in BE_BLOCKS else None, None)
            return "Changed the block at %d, %d, %d" % pos
        m = re.match(r"^forceload add (-?\d+) (-?\d+) (-?\d+) (-?\d+)$", text)
        if m:
            x1, z1, x2, z2 = (int(m.group(i)) for i in (1, 2, 3, 4))
            new = {(cx, cz) for cx in range(min(x1, x2) >> 4, (max(x1, x2) >> 4) + 1)
                   for cz in range(min(z1, z2) >> 4, (max(z1, z2) >> 4) + 1)} - self.forced
            self.forced |= new
            return "Marked %d chunks in minecraft:overworld to be force loaded" % len(new) if new else "No chunks were marked for force loading"
        m = re.match(r"^forceload query (-?\d+) (-?\d+)$", text)
        if m:
            cx, cz = int(m.group(1)) >> 4, int(m.group(2)) >> 4
            return "Chunk at (%d, %d) in minecraft:overworld is %smarked for force loading" % (cx, cz, "" if (cx, cz) in self.forced else "not ")
        if text.startswith(("computercraft ", "time query")):
            return "ok"
        raise AssertionError("the fake server does not know %r" % text)

    @staticmethod
    def default_prop(bid, k):
        return {"waterlogged": "false"}.get(k)

    def computers(self):
        return {b[3]: {"on": True, "pos": p} for p, b in self.blocks.items() if b[3] is not None}

    def block_data(self, pos, path=""):
        return self.command(("data get block %d %d %d %s" % (tuple(pos) + (path,))).strip())

    def spawn_computer(self, x, y, z, startup, files=None, modem=True):
        for p in ((x, y, z), (x, y + 1, z)):
            assert self.at(p)[0] in ("minecraft:air", "minecraft:cave_air"), "spawn_computer on a non-air cell %s" % (p,)
        self.next_id += 1
        cid = self.next_id
        self.blocks[(x, y, z)] = ("computercraft:computer_advanced", {}, None, cid)
        if modem:
            self.blocks[(x, y + 1, z)] = ("computercraft:wireless_modem_advanced", {"facing": "down"}, None, None)
        with open(startup, encoding="utf8") as f:
            self.spawned.append({"id": cid, "pos": (x, y, z), "startup": f.read(), "files": dict(files or {})})
        return cid

    def save_point(self, name):
        self.saved.append(name)
        return name

    def world_restart(self):
        self.restarts = getattr(self, "restarts", 0) + 1
        return "restarted"

    def tick_rate(self, rate):
        self.sent.append("tickrate %d" % rate)


class FakeCtx:
    def __init__(self, server):
        self.control = server
        self._raw = server
        self.pin = "HEAD"
        self.interventions = []
        self.notes = []
        self.run = tempfile.mkdtemp(prefix="shakeout_world_test")

    def note(self, text):
        self.notes.append(text)


CELLS = world.dock_cells()
WORKER_FREQ = "{left: 0, middle: 0, right: 0}"
SUPPORT_FREQ = "{left: 0, middle: 0, right: 14}"


def bay1_cell(cell):
    return next(c for c in CELLS if c["bay"] == 1 and c["side"] == cell["side"] and c["row"] == cell["row"] and c["slot"] == cell["slot"])


def seeded():
    """The test world's shape as the 2026-10-18 copy has it (read offline from its region files, see the task report): a floor at y 66
    everywhere, bay 1's under-dock blocks (worker bay 1: factory blocks left of the centre column, ender chests right of it; support bay 1:
    ender chests), bay 1's pillar east of it, bays 2-5 with the wrong or no under-blocks and no pillars, old turtles on docks."""
    s = FakeServer()
    s.put(world.RS_CONTROLLER, "refinedstorage:controller")
    for x in range(140, 236):
        for z in range(-2816, -2786):
            s.put((x, 66, z), "xkdeco:factory_block")
    for c in CELLS:
        under = (c["x"], c["y"] - 1, c["z"])
        rot = "0b" if c["row"] == "A" else "2b"
        if c["bay"] == 1:
            if c["side"] == "SUPPORT":
                s.put(under, "enderstorage:ender_chest{rot: %s, keepPacked: 0b, Frequency: %s}" % (rot, SUPPORT_FREQ))
            elif c["slot"] > 0:
                s.put(under, "enderstorage:ender_chest{rot: %s, keepPacked: 0b, Frequency: %s}" % (rot, WORKER_FREQ))
        elif c["side"] == "WORKER" and c["bay"] == 2 and c["row"] == "A" and c["slot"] > 0:
            s.put(under, "enderstorage:ender_chest{rot: 2b, keepPacked: 0b, Frequency: %s}" % WORKER_FREQ)   # right chest, lid the other way
        elif c["side"] == "WORKER" and c["bay"] == 2:
            s.put(under, "enderstorage:ender_chest{rot: 2b, keepPacked: 0b, Frequency: {left: 5, middle: 0, right: 0}}")   # wrong frequency
        elif c["side"] == "SUPPORT" and c["bay"] in (2, 3):
            s.blocks.pop(under, None)                                                                                   # a hole
    for pz in (-2808, -2795):
        for y in (67, 68):
            s.put((164, y, pz), "xkdeco:factory_danger")
        for y in (69, 70, 71):
            s.put((164, y, pz), "minecraft:stone_slab[type=double]")
    s.put((157, 66, -2804), "minecraft:light_blue_concrete")       # bay 1's centre column, a floor cell that differs from the default
    s.put((153, 67, -2806), "computercraft:turtle_advanced[facing=south]", cid=96)      # old fleet on docks
    s.put((158, 67, -2797), "computercraft:turtle_advanced[facing=north]", cid=97)
    s.put((167, 67, -2810), "computercraft:turtle_advanced[facing=south]", cid=98)
    s.put((185, 67, -2808), "computercraft:turtle_advanced[facing=south]", cid=99)      # a stray in bay 3's aisle
    for i, p in enumerate([(164, 67, -2812), (164, 67, -2811), (164, 67, -2810), (164, 67, -2809), (165, 67, -2810)]):
        s.put(p, "computercraft:turtle_advanced[facing=south]", cid=100 + i)            # between bays 1 and 2, as in the copy
    s.put((164, 67, -2807), "computercraft:computer_advanced[facing=north]", cid=105)
    s.put((183, 66, -2812), "enderstorage:ender_chest{rot: 0b, keepPacked: 0b, Frequency: {left: 3, middle: 3, right: 3}}")  # a floor chest
    return s


BETWEEN_BAYS = {100: (164, 67, -2812), 101: (164, 67, -2811), 102: (164, 67, -2810), 103: (164, 67, -2809), 104: (165, 67, -2810),
                105: (164, 67, -2807)}


def expected_source(s, c):
    """The ruling of 2026-11-10, written out on its own: bay 1's twin when a chest is under it, else the nearest bay-1 dock in the same
    side and row with a chest (by slot, lower slot on a tie)."""
    row = [d for d in CELLS if d["bay"] == 1 and d["side"] == c["side"] and d["row"] == c["row"]]
    for d in [bay1_cell(c)] + sorted(row, key=lambda d: (abs(d["slot"] - c["slot"]), d["slot"])):
        if s.at((d["x"], d["y"] - 1, d["z"]))[0] == "enderstorage:ender_chest":
            return d
    raise AssertionError("no chest in the row")


def built():
    s = seeded()
    ctx = FakeCtx(s)
    world.atc_files = lambda pin: ("-- atc.lua at %s\n" % pin, dict({n: "-- %s\n" % n for n in world.atc_file_names()}, **{"role.txt": "atc"}))
    report = world.build_world(ctx)
    return s, ctx, report


class DockCells(unittest.TestCase):
    def test_dock_cells_match_waypoints(self):
        self.assertEqual(len(CELLS), 160)
        types = {}
        for c in CELLS:
            types.setdefault((c["side"], c["bay"]), set()).add(c["type"])
            self.assertEqual(set(c) >= {"type", "bay", "row", "x", "y", "z", "facing"}, True, c)
        self.assertEqual(types[("WORKER", 1)], {"DELIVERY"})
        self.assertEqual(types[("SUPPORT", 1)], {"SUPPORT"})
        for b in range(2, 6):
            self.assertEqual(types[("WORKER", b)], {"MINER"})
            self.assertEqual(types[("SUPPORT", b)], {"MINER"})
        self.assertEqual(len({(c["x"], c["z"]) for c in CELLS}), 160, "no two docks share a cell")
        first = CELLS[0]
        self.assertEqual((first["type"], first["x"], first["y"], first["z"], first["facing"]), ("DELIVERY", 153, 67, -2806, "south"))

    def test_dock_cells_are_read_from_waypoints_not_retyped(self):
        tmp = tempfile.mkdtemp(prefix="wp")
        try:
            with open(os.path.join(REPO, "waypoints.lua"), encoding="utf8") as f:
                text = f.read()
            changed = text.replace('WORKER  = { "DELIVERY", "MINER",', 'WORKER  = { "DELIVERY", "DELIVERY",', 1)
            self.assertNotEqual(text, changed, "the test's edit must hit waypoints.lua's BAY_TYPES")
            path = os.path.join(tmp, "waypoints.lua")
            with open(path, "w", encoding="utf8", newline="\n") as f:
                f.write(changed)
            cells = world.dock_cells(path)
            self.assertEqual(sum(1 for c in cells if c["type"] == "DELIVERY"), 32)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class Forceload(unittest.TestCase):
    def test_forceload_covers_arrivals(self):
        self.assertTrue(world.covers(world.BASE_AREAS, 224, -2816, 271, -2769))
        self.assertFalse(world.covers(world.BASE_AREAS, 224, -2816, 400, -2769), "covers() can say no")

    def test_base_areas_cover_the_building_holes_and_every_gps_host(self):
        for x, z in ((143, -2813), (228, -2782), (136, -2802), (148, -2829)):     # dispatch hole, arrivals hole, server, warehouse
            self.assertTrue(world.covers(world.BASE_AREAS, x, z, x, z), (x, z))
        for c in CELLS:
            self.assertTrue(world.covers(world.BASE_AREAS, c["x"], c["z"], c["x"], c["z"]), c)
        for x, y, z in list(world.GPS_TOWERS) + list(world.EXISTING_GPS_HOSTS):
            self.assertTrue(world.covers(world.BASE_AREAS, x, z, x, z), (x, y, z))

    def test_build_world_forceloads_every_area(self):
        s, ctx, report = built()
        for (x1, z1, x2, z2) in world.BASE_AREAS:
            self.assertIn("forceload add %d %d %d %d" % (x1, z1, x2, z2), s.sent)
        self.assertEqual(world.area_chunks(world.BASE_AREAS), s.forced)


class NoClones(unittest.TestCase):
    def test_build_never_clones_turtles(self):
        s, ctx, report = built()
        self.assertEqual(world.clone_violations(s.sent), [])
        self.assertFalse([t for t in s.sent if t.split()[0] == "clone"], "the builder uses setblock only")

    def test_the_clone_check_can_fail(self):
        box = "clone 150 66 -2812 162 70 -2790 164 66 -2812"
        self.assertEqual(len(world.clone_violations([box])), 1, "a bare clone is a violation")
        cleaned = [box, "fill 164 66 -2812 176 70 -2790 minecraft:air replace computercraft:turtle_advanced",
                   "fill 164 66 -2812 176 70 -2790 minecraft:air replace computercraft:turtle_normal"]
        self.assertEqual(world.clone_violations(cleaned), [], "cloned, then every turtle kind removed from the same box")
        late = [box, "t2 resume"] + cleaned[1:]
        self.assertEqual(len(world.clone_violations(late)), 1, "a resume before the removal is a violation")
        small = [box, "fill 164 66 -2812 170 70 -2790 minecraft:air replace computercraft:turtle_advanced",
                 "fill 164 66 -2812 170 70 -2790 minecraft:air replace computercraft:turtle_normal"]
        self.assertEqual(len(world.clone_violations(small)), 1, "a removal that misses part of the box is a violation")


class UnderDock(unittest.TestCase):
    def test_under_dock_copies_nbt(self):
        before = seeded()
        s, ctx, report = built()
        new = [c for c in CELLS if c["bay"] != 1]
        self.assertEqual(len(new), 128)
        kept, fallback = 0, 0
        for c in new:
            src = expected_source(before, c)
            fallback += 1 if src is not bay1_cell(c) else 0
            spos, dpos = (src["x"], src["y"] - 1, src["z"]), (c["x"], c["y"] - 1, c["z"])
            want_id, _, want_nbt, _ = s.at(spos)
            self.assertEqual(want_id, "enderstorage:ender_chest")
            sets = [t for t in s.sent if t.startswith("setblock %d %d %d " % dpos) and "minecraft:air" not in t]
            b = before.at(dpos)
            if b[0] == want_id and world.chest_identity("{%s}" % b[2]) == world.chest_identity("{%s}" % want_nbt):
                kept += 1                                     # already the right chest: left alone
                self.assertEqual(sets, [], dpos)
            else:
                self.assertTrue(sets, "a setblock under %s" % (dpos,))
                got_id, _, got_nbt = split_spec(sets[-1].split(" ", 4)[4])
                self.assertEqual(got_id, want_id, dpos)
                self.assertEqual(world.canonical_nbt(got_nbt), world.canonical_nbt("{%s}" % want_nbt), dpos)
                self.assertIn(world.frequency_of(re.sub(r"\s+", "", want_nbt)), re.sub(r"\s+", "", got_nbt))
            self.assertEqual(s.at(dpos)[0], "enderstorage:ender_chest", dpos)
            self.assertEqual(world.chest_identity("{%s}" % s.at(dpos)[2]), world.chest_identity("{%s}" % want_nbt), dpos)
        self.assertEqual(fallback, 32, "worker bays 2-5 west of the centre column: worker bay 1 has no chest there")
        self.assertEqual(kept, 4, "worker bay 2 row A east: the right chest was already there")
        self.assertEqual((report["under"]["copied"], report["under"]["same"], report["under"]["fallback"]), (124, 4, 32))

    def test_the_fallback_takes_the_nearest_chest_in_the_same_row(self):
        s, ctx, report = built()
        src = report["under"]["sources"]
        self.assertEqual(src[(181, 66, -2806)], (158, 66, -2806), "bay 3 row A slot -4: bay 1 row A slot +1")
        self.assertEqual(src[(184, 66, -2810)], (158, 66, -2810), "bay 3 row B slot -1: bay 1 row B slot +1")
        self.assertEqual(src[(188, 66, -2810)], (160, 66, -2810), "bay 3 row B slot +3: its own twin")
        self.assertEqual(src[(171 - 4, 66, -2797)], (153, 66, -2797), "support bay 2 row A slot -4: its own twin")

    def test_no_chest_is_ever_replaced_with_anything_but_a_chest(self):
        before = seeded()
        s, ctx, report = built()
        chests = [p for p, b in before.blocks.items() if b[0] == "enderstorage:ender_chest"]
        self.assertGreater(len(chests), 40)
        for p in chests:
            self.assertEqual(s.at(p)[0], "enderstorage:ender_chest", "a chest at %s is gone" % (p,))
            for t in s.sent:
                if t.startswith("setblock %d %d %d " % p) and "minecraft:air" not in t:
                    self.assertTrue(t.split(" ", 4)[4].startswith("enderstorage:ender_chest"), t)
        self.assertEqual(report["floor"]["chests_kept"], [(183, 66, -2812)], "a chest in a floor cell is kept, not floored over")

    def test_the_position_keys_are_not_copied(self):
        nbt = world.nbt_without_position('{x: 158, y: 66, z: -2806, id: "enderstorage:ender_chest", rot: 0b, Frequency: {left: 0, middle: 0, right: 14}}')
        self.assertEqual(nbt, "{rot:0b,Frequency:{left:0,middle:0,right:14}}")
        self.assertEqual(world.canonical_nbt("{b: 1, a: {d: \"x y\", c: [I; 1, 2]}}"), world.canonical_nbt('{a:{c:[I;1,2],d:"x y"},b:1}'))
        self.assertNotEqual(world.canonical_nbt("{a: 1}"), world.canonical_nbt("{a: 2}"))

    def test_a_second_build_changes_nothing_under_the_docks(self):
        s, ctx, report = built()
        n = len(s.sent)
        report2 = world.build_world(ctx)
        changes = [t for t in s.sent[n:] if t.startswith("setblock")]
        self.assertEqual(report2["under"]["copied"], 0)
        self.assertEqual(report2["under"]["same"], 128)
        self.assertFalse([t for t in changes if " 66 " in t], "no under-dock or floor block is set again")


class Bays(unittest.TestCase):
    def test_every_dock_cell_is_air_and_old_turtles_are_reported(self):
        s, ctx, report = built()
        for c in CELLS:
            self.assertEqual(s.at((c["x"], c["y"], c["z"]))[0], "minecraft:air", c)
        removed = {r["id"] for r in report["removed"]}
        self.assertEqual(removed, {96, 97, 98}, "turtles on dock cells are removed and named")
        self.assertTrue(all(r["why"] == "dock cell" for r in report["removed"]), "nothing but dock cells loses a turtle")
        self.assertEqual(s.at((185, 67, -2808))[3], 99, "a turtle in a bay aisle is left standing")
        self.assertEqual([r["id"] for r in report["left_standing"]], [99], "...and named")
        for cid, p in BETWEEN_BAYS.items():
            self.assertEqual(s.at(p)[3], cid, "the turtles and computer between bays 1 and 2 are untouched")
            self.assertFalse([t for t in s.sent if t.startswith("setblock %d %d %d " % p)], p)

    def test_floor_and_pillars_copied_from_bay_1(self):
        s, ctx, report = built()
        for b in range(2, 6):
            cx = 157 + 14 * (b - 1)
            self.assertEqual(s.at((cx, 66, -2804))[0], "minecraft:light_blue_concrete", "bay %d's centre column floor" % b)
            px = cx + 7
            for pz in (-2808, -2795):
                self.assertEqual([s.at((px, y, pz))[0] for y in (67, 68, 69, 71, 72)],
                                 ["xkdeco:factory_danger"] * 2 + ["minecraft:stone_slab"] * 2 + ["minecraft:air"], (px, pz))
                self.assertEqual(s.at((px, 70, pz))[1], {"type": "double"})

    def test_an_unknown_block_in_bay_1_stops_the_build(self):
        s = seeded()
        s.put((158, 66, -2806), "minecraft:sponge")
        world.atc_files = lambda pin: ("-- atc\n", {"role.txt": "atc"})
        with self.assertRaises(world.UnknownBlock):
            world.build_world(FakeCtx(s))


class Verify(unittest.TestCase):
    def test_verify_passes_on_the_built_world_and_counts_evidence(self):
        s, ctx, report = built()
        v = world.verify_world(ctx)
        self.assertEqual((v["dock_air"], v["dock_total"]), (160, 160))
        self.assertEqual((v["under_ok"], v["under_total"]), (128, 128))
        self.assertEqual((v["under_exact"], v["under_fallback"]), (124, 32), "4 kept chests differ only in their lid direction")
        self.assertEqual(v["bad"], [])

    def test_verify_can_fail(self):
        s, ctx, report = built()
        s.put((172, 66, -2806), "enderstorage:ender_chest{rot: 0b, keepPacked: 0b, Frequency: {left: 1, middle: 0, right: 0}}")
        s.put((181, 66, -2810), "xkdeco:factory_block")
        s.put((209, 67, -2797), "computercraft:turtle_advanced", cid=7)
        v = world.verify_world(ctx)
        self.assertEqual(v["under_ok"], 126, "a wrong frequency and a floor block instead of a chest both fail")
        self.assertEqual(v["dock_air"], 159)
        self.assertEqual(len(v["bad"]), 3)


class RsCapacity(unittest.TestCase):
    def test_a_coloured_controller_is_found(self):
        s = seeded()
        s.blocks.pop(world.RS_CONTROLLER)
        s.put(world.RS_CONTROLLER, "refinedstorage:magenta_controller")
        self.assertEqual(world.add_rs_capacity(FakeCtx(s).control)["controller"], "refinedstorage:magenta_controller")

    def test_no_controller_at_the_position_is_an_error(self):
        s = seeded()
        s.blocks.pop(world.RS_CONTROLLER)
        with self.assertRaises(RuntimeError):
            world.add_rs_capacity(FakeCtx(s).control)

    def test_restart_after_build_is_one_world_restart_and_puts_the_tick_rate_back(self):
        s = seeded()
        ctx = FakeCtx(s)
        ctx.rate = 40
        world.restart_after_build(ctx)
        self.assertEqual(s.restarts, 1)
        self.assertIn("tickrate 40", s.sent)

    def test_restart_after_build_turns_the_t2_logs_back_on(self):
        # final review: the control mod's radio and event logs live in JVM memory; setup's restart must re-enable them for --t2logs
        s = seeded()
        s.radio_log = lambda state="on": s.sent.append("t2 radio log " + state)
        s.events_log = lambda state="on": s.sent.append("t2 events log " + state)
        ctx = FakeCtx(s)
        ctx.t2logs = True
        world.restart_after_build(ctx)
        self.assertIn("t2 radio log on", s.sent)
        self.assertIn("t2 events log on", s.sent)
        plain = seeded()
        plain.radio_log = lambda state="on": plain.sent.append("t2 radio log " + state)
        world.restart_after_build(FakeCtx(plain))
        self.assertNotIn("t2 radio log on", plain.sent, "only when the run asked for them")

    def faces(self):
        x, y, z = world.RS_CONTROLLER
        return [(x + dx, y + dy, z + dz) for dx, dy, dz in world.RS_NEIGHBOURS]

    def test_build_adds_a_creative_storage_block_next_to_the_controller(self):
        s, ctx, report = built()
        rs = report["rs_capacity"]
        self.assertTrue(rs["placed"] and rs["controller"], rs)
        self.assertIn(rs["pos"], self.faces())
        self.assertEqual(s.at(rs["pos"])[0], world.RS_CREATIVE_BLOCK)
        self.assertEqual(sum(1 for p in self.faces() if s.at(p)[0] == world.RS_CREATIVE_BLOCK), 1)

    def test_a_second_build_adds_no_second_block(self):
        s, ctx, report = built()
        report2 = world.build_world(ctx)
        self.assertFalse(report2["rs_capacity"]["placed"])
        self.assertEqual(report2["rs_capacity"]["pos"], report["rs_capacity"]["pos"])
        self.assertEqual(sum(1 for p in self.faces() if s.at(p)[0] == world.RS_CREATIVE_BLOCK), 1)

    def test_a_blocked_face_is_skipped_and_no_face_at_all_is_an_error(self):
        s = seeded()
        x, y, z = world.RS_CONTROLLER
        s.put((x + 1, y, z), "minecraft:stone")
        self.assertEqual(world.add_rs_capacity(FakeCtx(s).control)["pos"], (x - 1, y, z))
        s2 = seeded()
        for p in self.faces():
            s2.put(p, "minecraft:stone")
        with self.assertRaises(RuntimeError):
            world.add_rs_capacity(FakeCtx(s2).control)


class Gps(unittest.TestCase):
    def test_at_least_eight_new_towers_spread_out(self):
        t = world.GPS_TOWERS
        self.assertGreaterEqual(len(t), 8)
        self.assertEqual(len(set(t)), len(t))
        self.assertGreaterEqual(len({y for _, y, _ in t}), 6, "different heights")
        self.assertFalse(set(t) & set(world.EXISTING_GPS_HOSTS))
        self.assertGreater(world.spread_volume(t), 10000, "not on one plane: the best tetrahedron of towers is big")
        self.assertLess(world.spread_volume([(0, 90, 0), (10, 90, 0), (0, 90, 10), (10, 90, 10)]), 1e-9, "spread_volume can say flat")

    def test_trilateration_from_the_new_towers_alone_finds_the_probe(self):
        probe = (131, 70, -2845)
        fixes = [{"pos": t, "d": sum((a - b) ** 2 for a, b in zip(t, probe)) ** 0.5} for t in world.GPS_TOWERS]
        pos, rms = world.trilaterate(fixes)
        self.assertLess(max(abs(a - b) for a, b in zip(pos, probe)), 0.01)
        self.assertLess(rms, 0.01)
        bad = [dict(f, d=f["d"] + 3) if i == 0 else f for i, f in enumerate(fixes)]
        self.assertGreater(world.trilaterate(bad)[1], 0.1, "a wrong distance shows in the residual")

    def test_towers_are_placed_as_gps_hosts_the_kit_can_find(self):
        s, ctx, report = built()
        hosts = [sp for sp in s.spawned if "gps" in sp["startup"]]
        self.assertEqual(sorted(sp["pos"] for sp in hosts), sorted(world.GPS_TOWERS))
        programs = {sp["id"]: sp["startup"] for sp in hosts}
        self.assertEqual(control.Control.match_gps_hosts(programs, {}), sorted(programs), "gps_down/gps_up will find every new tower")
        for sp in hosts:
            x, y, z = sp["pos"]
            self.assertEqual(sp["startup"], 'shell.run("gps", "host", %d, %d, %d)\n' % (x, y, z),
                             "it announces its own computer block, where CC measures a down-facing modem from")
        self.assertEqual(len(report["gps"]), len(world.GPS_TOWERS))
        self.assertEqual(report["gps_blocked"], [])

    def test_a_blocked_tower_is_reported_not_moved(self):
        s = seeded()
        x, y, z = world.GPS_TOWERS[0]
        s.put((x, y + 1, z), "minecraft:stone")
        world.atc_files = lambda pin: ("-- atc\n", {"role.txt": "atc"})
        report = world.build_world(FakeCtx(s))
        self.assertEqual([b["pos"] for b in report["gps_blocked"]], [(x, y, z)])
        self.assertEqual(len(report["gps"]), len(world.GPS_TOWERS) - 1)


class Atc(unittest.TestCase):
    def test_the_atc_computer_gets_the_atc_profile_from_the_pin(self):
        s, ctx, report = built()
        atc = [sp for sp in s.spawned if sp["startup"].startswith("-- atc.lua")]
        self.assertEqual(len(atc), 1)
        self.assertEqual(atc[0]["startup"], "-- atc.lua at HEAD\n")
        self.assertEqual(set(atc[0]["files"]), set(world.atc_file_names()) | {"role.txt"})
        self.assertEqual(atc[0]["files"]["role.txt"], "atc")
        self.assertEqual(report["atc"]["id"], atc[0]["id"])
        x, y, z = atc[0]["pos"]
        self.assertFalse(any(abs(x - c["x"]) <= 5 and abs(z - c["z"]) <= 4 for c in CELLS), "the ATC stands in no bay")

    def test_atc_file_names_are_w3s(self):
        self.assertEqual(tuple(world.atc_file_names()), ("protocol.lua", "updater.lua", "logship.lua", "waypoints.lua"))


class SavePoint(unittest.TestCase):
    def test_save_point_is_the_control_verb(self):
        s = FakeServer()
        world.save_point(FakeCtx(s), "shakeout-world")
        self.assertEqual(s.saved, ["shakeout-world"])


def load_proof():
    import importlib.util
    spec = importlib.util.spec_from_file_location("shakeout_world_proof", os.path.join(HERE, "..", "t2", "scenarios", "shakeout_world.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


HOST_CALL = re.compile(r'shell\.run\("gps", "host", (-?\d+), (-?\d+), (-?\d+)\)')


class ProofServer(FakeServer):
    """FakeServer plus what the T2 proof uses: disks, gps_hosts, shutdown, a real save-point folder, and a probe computer that hears
    every host that is up and writes gps_probe.json as the probe Lua would. Distances are measured between COMPUTER blocks (CC:Tweaked
    1.20.1: a down-facing modem reports the block it faces), each host replies with the coordinates its program ANNOUNCES, and the
    fix is the least-squares answer to those replies rounded to 0.01, as gps.locate rounds. drop_nbt: setblock ignores a chest's NBT
    (the chest then shows the game's defaults)."""

    def __init__(self, deaf_to=(), drop_nbt=False):
        FakeServer.__init__(self)
        self.blocks = seeded().blocks                     # the world copy's shape, old turtles on docks and all
        self.disks = tempfile.mkdtemp(prefix="shakeout_disks")
        self.deaf_to = set(deaf_to)
        self.drop_nbt = drop_nbt

    def command(self, text):
        if self.drop_nbt and text.startswith("setblock") and "enderstorage:ender_chest{" in text:
            text = text.split("{", 1)[0]
        return FakeServer.command(self, text)

    def gps_hosts(self):
        return sorted(sp["id"] for sp in self.spawned if sp["startup"].startswith('shell.run("gps"'))

    def shutdown(self, ids):
        self.sent.extend("computercraft shutdown #%d" % i for i in ids)

    def save_point(self, name):
        dest = os.path.join(self.disks, "savepoints", name)
        os.makedirs(dest)
        open(os.path.join(dest, "level.dat"), "w").close()
        return dest

    def spawn_computer(self, x, y, z, startup, files=None, modem=True):
        cid = FakeServer.spawn_computer(self, x, y, z, startup, files, modem)
        if "gps_probe.json" in self.spawned[-1]["startup"]:
            me = (x, y, z)                                 # measured from the probe's computer block
            hosts_up = [(tuple(int(v) for v in HOST_CALL.match(sp["startup"]).groups()), sp["pos"])
                        for sp in self.spawned if sp["startup"].startswith('shell.run("gps"')]
            hosts_up += [(h, h) for h in world.EXISTING_GPS_HOSTS]
            hosts = [{"pos": list(said), "d": sum((a - b) ** 2 for a, b in zip(at, me)) ** 0.5}
                     for said, at in hosts_up if said not in self.deaf_to]
            fix = None
            if len(hosts) >= 4:
                pos, _ = world.trilaterate([{"pos": tuple(h["pos"]), "d": h["d"]} for h in hosts])
                fix = [round(v, 2) for v in pos] if pos else None
            os.makedirs(os.path.join(self.disks, str(cid)))
            with open(os.path.join(self.disks, str(cid), "gps_probe.json"), "w") as f:
                f.write(__import__("json").dumps({"t": 1, "fix": fix, "hosts": hosts}))
        return cid


class ProofCtx(FakeCtx):
    def __init__(self, server):
        FakeCtx.__init__(self, server)
        self.checks = []

    @property
    def interventions(self):
        return [{"verb": "command", "args": [repr(t)]} for t in self.control.sent
                if __import__("scenario").world_changing_command(t)]

    @interventions.setter
    def interventions(self, v):
        pass

    def log_lines(self, substr=""):
        atc = any(sp["files"].get("role.txt") == "atc" for sp in self.control.spawned)
        return ["2026-11-10T00:00:00Z atc#1 INFO ATC online"] if atc and substr == "ATC online" else []

    def wait_until(self, cond, game_seconds, poll=10):
        return cond() or None

    def wait_game(self, seconds, poll=10):
        pass

    def expect(self, ok, message):
        self.checks.append((bool(ok), message))


class ProofScenario(unittest.TestCase):
    """The unrun T2 proof, driven against the fake: every check passes on a correct build, and its checks can fail."""

    def run_proof(self, server):
        world.atc_files = lambda pin: ("-- atc.lua\n", dict({n: "--\n" for n in world.atc_file_names()}, **{"role.txt": "atc"}))
        ctx = ProofCtx(server)
        load_proof().steps(ctx)
        return ctx

    def test_every_check_passes_on_a_correct_build(self):
        server = ProofServer()
        ctx = self.run_proof(server)
        self.assertEqual(server.restarts, 1, "the proof restarts the world once after the build, before reading RS capacity")
        self.assertGreaterEqual(len(ctx.checks), 15)
        self.assertEqual([m for ok, m in ctx.checks if not ok], [])
        self.assertTrue(any("160 of 160" in m for _, m in ctx.checks))
        self.assertTrue(any("ender chest" in m and "128 of 128" in m and "32 from the nearest" in m for _, m in ctx.checks))
        self.assertTrue(any("0 clone(s)" in m and "recorded console commands" in m for _, m in ctx.checks))

    def test_the_gps_checks_fail_when_new_towers_are_silent(self):
        silent = [tuple(t) for t in world.GPS_TOWERS[:7]]
        ctx = self.run_proof(ProofServer(deaf_to=silent))
        failed = [m for ok, m in ctx.checks if not ok]
        self.assertTrue(any("GPS hosts (need all 12" in m for m in failed), failed)
        self.assertTrue(any("NEW towers" in m for m in failed), failed)

    def test_one_silent_new_tower_fails_the_hosts_check_at_every_probe(self):
        # final review: "at least 6 heard" passed with a new tower silent (11 >= 6); every host must be heard at every probe
        ctx = self.run_proof(ProofServer(deaf_to=[tuple(world.GPS_TOWERS[3])]))
        failed = [m for ok, m in ctx.checks if not ok and "GPS hosts (need all 12" in m]
        self.assertEqual(len(failed), 3, [m for ok, m in ctx.checks if not ok])
        self.assertTrue(all("7 of the 8 new towers" in m for m in failed), failed)


    def test_a_tower_announcing_its_modem_makes_the_gps_checks_fail(self):
        """The control for the T2 run: one tower announcing y+1 (its modem, the old mistake) must fail the fix checks."""
        right = world.gps_host_program
        wrong = tuple(world.GPS_TOWERS[0])
        world.gps_host_program = lambda tw: right((tw[0], tw[1] + 1, tw[2])) if tuple(tw) == wrong else right(tw)
        try:
            ctx = self.run_proof(ProofServer())
        finally:
            world.gps_host_program = right
        failed = [m for ok, m in ctx.checks if not ok]
        self.assertTrue(any(m.startswith("gps.locate at") for m in failed), failed)
        self.assertTrue(any("NEW towers" in m for m in failed), failed)
        self.assertFalse([m for m in failed if "GPS hosts (need all 12" in m], "it still hears every host: only the offset fails")

    def test_a_tower_computer_that_is_off_fails_a_check_that_names_it(self):
        """shakeout-world-a: the 8th tower saved On=0; gps_hosts() reads disks so it still counted. The proof must name it."""
        class OffServer(ProofServer):
            def computers(self):
                out = ProofServer.computers(self)
                for i, v in out.items():
                    if v["pos"] == tuple(world.GPS_TOWERS[7]):
                        v["on"] = False
                return out
        ctx = self.run_proof(OffServer(deaf_to=[tuple(world.GPS_TOWERS[7])]))
        failed = [m for ok, m in ctx.checks if not ok]
        self.assertTrue(any("tower computer is on" in m and str(world.GPS_TOWERS[7]) in m for m in failed), failed)
        named = [m for m in failed if "GPS hosts (need all 12" in m]
        self.assertEqual(len(named), 3)
        self.assertTrue(all("not heard: [%s]" % (world.GPS_TOWERS[7],) in m for m in named), named)

    def test_silent_towers_names_the_missing_entries(self):
        heard = [{"pos": list(t), "d": 1.0} for t in world.GPS_TOWERS[:-1]]
        self.assertEqual(world.silent_towers(heard), [tuple(world.GPS_TOWERS[-1])])
        self.assertEqual(world.silent_towers([{"pos": list(t)} for t in world.GPS_TOWERS]), [])

    def test_spawn_computer_turns_a_computer_that_stays_off_on_again(self):
        class Stub:
            disks = tempfile.mkdtemp(prefix="stub_disks")
            def __init__(self, ignore):
                self.ignore, self.ons, self.state, self.n = ignore, 0, {}, 0
            def command(self, text):
                return "Changed the block"
            def computers(self):
                self.n += 1
                return {7: {"on": self.state.get(7, False), "pos": (1, 2, 3)}} if self.n > 1 else {}
            def shutdown(self, ids):
                pass
            def turn_on(self, ids):
                self.ons += 1
                if self.ons > self.ignore:
                    self.state[7] = True
        real = control.time.sleep
        control.time.sleep = lambda s: None
        try:
            f = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False); f.write("x"); f.close()
            ok = Stub(2)
            self.assertEqual(control.Control.spawn_computer(ok, 1, 2, 3, f.name), 7)
            self.assertEqual(ok.ons, 3)
            with self.assertRaises(RuntimeError):
                control.Control.spawn_computer(Stub(99), 1, 2, 3, f.name)
        finally:
            control.time.sleep = real

    def test_chest_nbt_that_is_not_applied_fails_the_read_back_but_not_the_128_check(self):
        """Why the read-back exists: bay 1 is on the default frequency, so chests set WITHOUT their NBT pass the 128-chest check."""
        server = ProofServer(drop_nbt=True)
        for p, b in list(server.blocks.items()):           # bay 1 all on the default frequency, as the real copy has it
            if b[2] and "right: 14" in b[2]:
                server.blocks[p] = (b[0], b[1], b[2].replace("right: 14", "right: 0"), b[3])
        ctx = self.run_proof(server)
        failed = [m for ok, m in ctx.checks if not ok]
        self.assertTrue(any("reads back with it" in m for m in failed), failed)
        self.assertFalse([m for m in failed if "128" in m], "the default-frequency chests look right to the 128-chest check")


if __name__ == "__main__":
    unittest.main()
