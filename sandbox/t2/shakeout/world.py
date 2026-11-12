"""Shakeout world builder (plan Task 4; spec section 4.2): turns the T2 world copy into the shakeout's test world.

    from shakeout import world
    report = world.build_world(ctx)          # ctx: a sandbox/t2/scenario.py Ctx (ctx.control records every change)
    world.verify_world(ctx)                  # dock cells air, under-dock blocks equal to bay 1's (counts, so a check can fail)
    world.save_point(ctx, "shakeout-world")  # the control verb: save-all, then a copy of the world under <run>/savepoints/

What build_world does, in order:
  1. forceloads BASE_AREAS (the building, both holes and their shafts, the arrivals column and holding line, every GPS host);
  2. empties every dock cell (all 160): a turtle or computer on a dock is removed and NAMED in the report (the world copy's old
     fleet stands on some docks; the shakeout places 160 fresh turtles there). Turtles are removed from DOCK CELLS ONLY: the rest
     of bays 2-5's driving level loses plain blocks, but a turtle or computer there (or in a pillar cell) is left standing and
     named in report["left_standing"];
  3. builds bays 2-5 on both sides from bay 1: the floor layer and the pillar east of the bay, cell by cell with setblock (never
     /clone: a cloned turtle is a copy of a computer), reading bay 1's blocks from the running world; an ender chest is never
     replaced with floor;
  4. puts an ender chest under each new dock cell, NBT included (the Frequency), copied from bay 1's dock in the same side, row
     and slot when that one has a chest, else from the nearest bay-1 dock in the same row that has one (worker bay 1 has none
     under its west half); a cell that already holds the right chest (lid direction aside) is left alone;
  5. places the ATC computer (spawn_computer, the atc profile's files from the pin: w3_atc_pair.py's show() and ATC_FILES);
  6. places a GPS host computer at each GPS_TOWERS entry (spawn_computer running the host call gps_host.lua makes).

Geometry comes from waypoints.lua through dock_cells.lua (run in the sandbox's Lua interpreter); no coordinate of a dock is typed
here. Bay 1's blocks are read at run time: a block's id and state by `execute if block` against BLOCK_CANDIDATES (a block that
matches none STOPS the build: it is never guessed), its NBT by `data get block`.
"""
import ast
import importlib.util
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
T2 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(T2, "..", ".."))
if T2 not in sys.path:
    sys.path.insert(0, T2)

# ---------------------------------------------------------------------------------------------------------------------------
# Areas and towers
# ---------------------------------------------------------------------------------------------------------------------------

# (x1, z1, x2, z2), inclusive block coordinates; `forceload add` takes them as they are.
BASE_AREAS = [
    (128, -2848, 239, -2769),   # the building: the server and admin computers (x 136), the dispatch hole and its shaft (143,-2813),
                                # the warehouse (148,72,-2829), all ten bays, the taxiways, the arrivals hole (228,-2782)
    (224, -2816, 271, -2769),   # the arrivals column, its shaft and tunnel taxi row, the holding line (spec 4.2.4: does not tick
                                # on its own in the T2 copy)
    (318, -2816, 331, -2805),   # the four GPS hosts the world already has
]

# The world's four GPS host computers. Their disks run shell.run("gps", "host", x, y, z) with these numbers, their OWN computer
# block, and that is right: the modem on top faces down, and CC:Tweaked 1.20.1's wireless modem reports as its position the block
# it faces (WirelessModemBlockEntity$Peripheral.getPosition: the modem's position stepped one block in its facing direction, checked
# in the test server's cc-tweaked-1.20.1-forge-1.120.2.jar). So distances are measured from the computer block. gps_host.lua says
# the same: "the actual coordinates of THIS computer".
EXISTING_GPS_HOSTS = [(322, 92, -2814), (322, 92, -2809), (327, 92, -2814), (322, 96, -2814)]

# New GPS host computers (spawn_computer puts the modem on top, facing down; each announces its own computer block). Spread over the whole base area at six different heights, so no four of
# them are near one plane, all inside BASE_AREAS (kept loaded), all above the roof (y 85-87) and below 160 (the lowest travel and
# lease heights the fleet uses are 160-175), and none on the dispatch column (143,-2813), the arrivals column (228,-2782) or the
# holding line (x 228-256, z -2782..-2778).
GPS_TOWERS = [
    (130, 95, -2846),    # north-west corner of the building area
    (238, 110, -2846),   # north-east corner
    (130, 125, -2771),   # south-west corner
    (238, 140, -2771),   # south-east corner
    (184, 150, -2808),   # over the middle of the bays, the highest
    (184, 105, -2846),   # middle of the north edge
    (270, 100, -2771),   # far east, south (the arrivals area)
    (270, 130, -2815),   # far east, north
]

# Where the ATC computer may stand: on the building floor south of the support bays, in no ATC section and no dock (waypoints.lua:
# the support sections end at z -2790; x stays west of the arrivals column). The first free one is used.
ATC_CANDIDATES = [(x, 67, z) for z in (-2786, -2784) for x in range(160, 221, 4)]

# Block states `execute if block` is asked about, most common first. Every block the 2026-10-18 copy has in bay 1's floor, under its
# docks and in its pillars is here (read from its region files: factory_block, factory_danger, light_blue_concrete, ender_chest,
# double stone slabs). The slabs have block-state properties and are listed once per `type` (their `waterlogged` is left to the
# default, false, as it is in the copy). factory_block, factory_danger, ender_chest, the concretes, quartz_block, gravel, dirt,
# grass_block and stone have NO block-state properties in the copy's palette (checked offline), so the bare id is their whole state;
# an ender chest's lid direction is NBT (rot), copied with the rest of its NBT. A new block with properties must be listed per state
# here, or a copy would silently get its default state.
BLOCK_CANDIDATES = [
    "xkdeco:factory_block", "xkdeco:factory_danger", "enderstorage:ender_chest", "minecraft:light_blue_concrete",
    "minecraft:stone_slab[type=double]", "minecraft:stone_slab[type=top]", "minecraft:stone_slab[type=bottom]",
    "minecraft:white_concrete", "minecraft:red_concrete", "minecraft:gray_concrete",
    "minecraft:quartz_slab[type=top]", "minecraft:quartz_slab[type=bottom]", "minecraft:quartz_slab[type=double]",
    "minecraft:quartz_block", "minecraft:gravel", "minecraft:dirt", "minecraft:grass_block", "minecraft:stone",
    "minecraft:air", "minecraft:cave_air",
]
AIR = ("minecraft:air", "minecraft:cave_air")
PILLAR_MAX = 40          # a pillar is read upwards until air, at most this many blocks


class UnknownBlock(RuntimeError):
    """A bay-1 block matches no BLOCK_CANDIDATES entry: copying it would be a guess, so the build stops."""


# ---------------------------------------------------------------------------------------------------------------------------
# Dock cells, from waypoints.lua
# ---------------------------------------------------------------------------------------------------------------------------

def lua_interpreter():
    """The sandbox's interpreter (sandbox/interp.txt, lua52_det) when it is there, else `lua` on PATH (what tests/run.lua uses)."""
    try:
        with open(os.path.join(REPO, "sandbox", "interp.txt")) as f:
            exe = f.read().strip()
    except OSError:
        exe = ""
    return exe if exe and os.path.exists(exe) else "lua"


_CELLS = {}


def dock_cells(waypoints=None):
    """[dict(type, bay, row, side, slot, x, y, z, facing, aisle_z, return_z, lane_z)] for every dock of waypoints.lua, read by
    dock_cells.lua (never re-typed here). `waypoints` defaults to the repo's waypoints.lua."""
    path = os.path.abspath(waypoints or os.path.join(REPO, "waypoints.lua"))
    if path not in _CELLS:
        out = subprocess.run([lua_interpreter(), os.path.join(HERE, "dock_cells.lua"), path], capture_output=True, check=True)
        _CELLS[path] = json.loads(out.stdout.decode("utf8"))
    return [dict(c) for c in _CELLS[path]]


def bay_frames(cells):
    """{(side, bay): frame} where a frame is the bay side's footprint, from the dock geometry:
         centre   the centre column x (dock x - slot)
         xs       min dock x - 1 .. max dock x + 1 (the docks and the marked border round them)
         zs       from the cell next to the taxiway lane to the furthest aisle (waypoints' departure and return aisles)
         pillar   (x, z) of the pillar east of the bay: half a bay spacing east of the centre, between the two rows
         docks    {(x, z)} of the bay's dock cells
         y        the floor the turtles drive on (the docks' y)"""
    groups = {}
    for c in cells:
        groups.setdefault((c["side"], c["bay"]), []).append(c)
    centres = {k: v[0]["x"] - v[0]["slot"] for k, v in groups.items()}
    frames = {}
    for (side, bay), cs in groups.items():
        lane = cs[0]["lane_z"]
        sign = 1 if cs[0]["z"] > lane else -1
        far = [c["z"] for c in cs] + [c["aisle_z"] for c in cs] + [c["return_z"] for c in cs]
        far_z = max(far) if sign > 0 else min(far)
        near_z = lane + sign
        rows = sorted({c["z"] for c in cs})
        nxt = centres.get((side, 2), centres[(side, bay)] + 14) - centres[(side, 1)]
        frames[(side, bay)] = {
            "centre": centres[(side, bay)],
            "xs": (min(c["x"] for c in cs) - 1, max(c["x"] for c in cs) + 1),
            "zs": (min(near_z, far_z), max(near_z, far_z)),
            "pillar": (centres[(side, bay)] + nxt // 2, (rows[0] + rows[-1]) // 2),
            "docks": {(c["x"], c["z"]) for c in cs},
            "y": cs[0]["y"],
        }
    return frames


def bay1_twin(cells, cell):
    """Bay 1's dock in the same side, row and slot as `cell`."""
    for c in cells:
        if c["bay"] == 1 and c["side"] == cell["side"] and c["row"] == cell["row"] and c["slot"] == cell["slot"]:
            return c
    raise KeyError("no bay-1 dock for %s" % (cell,))


# ---------------------------------------------------------------------------------------------------------------------------
# Areas
# ---------------------------------------------------------------------------------------------------------------------------

def area_chunks(areas):
    """{(cx, cz)} of every chunk the areas touch."""
    out = set()
    for x1, z1, x2, z2 in areas:
        for cx in range(min(x1, x2) >> 4, (max(x1, x2) >> 4) + 1):
            for cz in range(min(z1, z2) >> 4, (max(z1, z2) >> 4) + 1):
                out.add((cx, cz))
    return out


def covers(areas, x1, z1, x2, z2):
    """True when every block column of the rectangle lies inside the areas (block coordinates, inclusive)."""
    for x in range(min(x1, x2), max(x1, x2) + 1):
        for z in range(min(z1, z2), max(z1, z2) + 1):
            if not any(min(a, c) <= x <= max(a, c) and min(b, d) <= z <= max(b, d) for a, b, c, d in areas):
                return False
    return True


# ---------------------------------------------------------------------------------------------------------------------------
# SNBT as `data get block` prints it
# ---------------------------------------------------------------------------------------------------------------------------

_BARE = re.compile(r"[A-Za-z0-9._+-]+")


def _parse(text, i):
    """(value, next index). A value is ("c", [(key, value)]), ("l", prefix, [values]), ("s", raw quoted text) or ("v", raw text)."""
    while text[i].isspace():
        i += 1
    ch = text[i]
    if ch == "{":
        i += 1
        items = []
        while True:
            while text[i].isspace() or text[i] == ",":
                i += 1
            if text[i] == "}":
                return ("c", items), i + 1
            if text[i] in "\"'":
                key, i = _parse(text, i)
                key = ast.literal_eval(key[1]) if key[1][0] == '"' else key[1][1:-1]
            else:
                m = _BARE.match(text, i)
                key, i = m.group(0), m.end()
            while text[i].isspace():
                i += 1
            assert text[i] == ":", "expected ':' at %d in %r" % (i, text)
            val, i = _parse(text, i + 1)
            items.append((key, val))
    if ch == "[":
        i += 1
        prefix = ""
        m = re.match(r"\s*([BIL])\s*;", text[i:])
        if m:
            prefix, i = m.group(1) + ";", i + m.end()
        vals = []
        while True:
            while text[i].isspace() or text[i] == ",":
                i += 1
            if text[i] == "]":
                return ("l", prefix, vals), i + 1
            v, i = _parse(text, i)
            vals.append(v)
    if ch in "\"'":
        j = i + 1
        while text[j] != ch:
            j += 2 if text[j] == "\\" else 1
        return ("s", text[i:j + 1]), j + 1
    m = re.compile(r"[^,:{}\[\]\s]+").match(text, i)
    return ("v", m.group(0)), m.end()


def parse_snbt(text):
    val, _ = _parse(text.strip(), 0)
    return val


def _key(k):
    return k if _BARE.fullmatch(k) else json.dumps(k)


def _dump(v, sort=False):
    if v[0] == "c":
        items = sorted(v[1], key=lambda kv: kv[0]) if sort else v[1]
        return "{" + ",".join("%s:%s" % (_key(k), _dump(x, sort)) for k, x in items) + "}"
    if v[0] == "l":
        return "[" + v[1] + ",".join(_dump(x, sort) for x in v[2]) + "]"
    return v[1]


POSITION_KEYS = ("x", "y", "z", "id")


def nbt_without_position(text):
    """A block entity's SNBT without x, y, z and id (the game sets those itself), compact, in its own key order."""
    v = parse_snbt(text)
    return _dump(("c", [(k, x) for k, x in v[1] if k not in POSITION_KEYS]))


def canonical_nbt(text, drop=()):
    """A comparable form: no position keys (nor the top-level keys in `drop`), no whitespace outside strings, compound keys sorted
    at every level. None stays None."""
    if text is None:
        return None
    v = parse_snbt(text)
    return _dump(("c", [(k, x) for k, x in v[1] if k not in POSITION_KEYS and k not in drop]), sort=True)


def nbt_of(reply):
    """The SNBT of a `data get block` reply, or None when the block has no block entity."""
    return reply.split("block data: ", 1)[1].strip() if "block data: " in reply else None


# ---------------------------------------------------------------------------------------------------------------------------
# Reuse: the ATC profile (W3's w3_atc_pair.py) and the frequency parser (shakeout_ender_tag.py)
# ---------------------------------------------------------------------------------------------------------------------------

def _scenario(name):
    spec = importlib.util.spec_from_file_location("_shakeout_" + name, os.path.join(T2, "scenarios", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_MODS = {}


def _mod(name):
    if name not in _MODS:
        _MODS[name] = _scenario(name)
    return _MODS[name]


def frequency_of(text):
    """shakeout_ender_tag.frequency_of: 'Frequency:{...}' out of block or item data, by balanced braces."""
    return _mod("shakeout_ender_tag").frequency_of(text)


def atc_file_names():
    return _mod("w3_atc_pair").ATC_FILES


def atc_files(pin):
    """(atc.lua text, {name: text}) for the ATC computer: atc.lua as its startup and w3_atc_pair.ATC_FILES beside it, all from the
    pinned commit (w3_atc_pair.show), plus role.txt 'atc'."""
    pair = _mod("w3_atc_pair")
    files = {name: pair.show(pin, name) for name in pair.ATC_FILES}
    files["role.txt"] = "atc"
    return pair.show(pin, "atc.lua"), files


# ---------------------------------------------------------------------------------------------------------------------------
# GPS
# ---------------------------------------------------------------------------------------------------------------------------

def gps_host_program(tower):
    """The startup.lua of a tower: the one call gps_host.lua makes, with the tower's OWN computer coordinates (where CC measures a
    down-facing modem's distances from: see EXISTING_GPS_HOSTS). Exactly the form the world's own hosts run, which
    Control.gps_hosts() recognises (so gps_down / gps_up reach the new towers too)."""
    return 'shell.run("gps", "host", %d, %d, %d)\n' % tuple(tower)


def silent_towers(heard, towers=None):
    """The GPS_TOWERS entries no reply in `heard` (a list of {"pos": [x, y, z], ...}) announced: a probe that hears 11 of 12 hosts
    must say WHICH one is missing."""
    said = {tuple(h["pos"]) for h in heard}
    return [tuple(t) for t in (GPS_TOWERS if towers is None else towers) if tuple(t) not in said]


def towers_off(computers, placed):
    """placed: [{"pos", "id"}] of towers; computers: Control.computers() ({id: {"on", "pos"}}). The towers whose computer is not on
    (a computer that is off answers no ping, and gps_hosts() reads disks, so it still lists it)."""
    return [(tuple(g["pos"]), g["id"]) for g in placed if not computers.get(g["id"], {}).get("on")]


def _det3(a, b, c):
    return (a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]))


def spread_volume(points):
    """The largest tetrahedron volume over any four of the points: 0 when they all lie on one plane."""
    best = 0.0
    for p, q, r, s in itertools.combinations(points, 4):
        d = [[q[i] - p[i] for i in range(3)], [r[i] - p[i] for i in range(3)], [s[i] - p[i] for i in range(3)]]
        best = max(best, abs(_det3(*d)) / 6.0)
    return best


def _solve3(m, v):
    """m x = v for a 3x3 m, by Cramer's rule; None if singular."""
    d = _det3(*m)
    if abs(d) < 1e-9:
        return None
    out = []
    for k in range(3):
        mk = [list(row) for row in m]
        for r in range(3):
            mk[r][k] = v[r]
        out.append(_det3(*mk) / d)
    return out


def trilaterate(fixes):
    """((x, y, z), rms distance error) from [{"pos": (x, y, z), "d": distance}], least squares over all of them (four or more, not
    on one plane). The answer to 'do these hosts alone give a fix, and is it right?'."""
    p0, d0 = fixes[0]["pos"], fixes[0]["d"]
    rows, rhs = [], []
    for f in fixes[1:]:
        p, d = f["pos"], f["d"]
        rows.append([2.0 * (p[i] - p0[i]) for i in range(3)])
        rhs.append(sum(p[i] ** 2 - p0[i] ** 2 for i in range(3)) - d * d + d0 * d0)
    ata = [[sum(r[i] * r[j] for r in rows) for j in range(3)] for i in range(3)]
    atb = [sum(r[i] * b for r, b in zip(rows, rhs)) for i in range(3)]
    x = _solve3(ata, atb)
    if x is None:
        return None, float("inf")
    err = [(sum((x[i] - f["pos"][i]) ** 2 for i in range(3)) ** 0.5 - f["d"]) for f in fixes]
    return tuple(x), (sum(e * e for e in err) / len(err)) ** 0.5


# ---------------------------------------------------------------------------------------------------------------------------
# Clones
# ---------------------------------------------------------------------------------------------------------------------------

TURTLE_KINDS = ("computercraft:turtle_normal", "computercraft:turtle_advanced")


def _box(nums):
    x1, y1, z1, x2, y2, z2 = nums
    return (min(x1, x2), min(y1, y2), min(z1, z2), max(x1, x2), max(y1, y2), max(z1, z2))


def _ticks(words):
    v = words[0]
    if v in ("tick", "tickrate"):
        return True
    if v == "t2" and len(words) > 1 and words[1] in ("resume", "step"):
        return True
    return v == "computercraft" and len(words) > 1 and words[1] == "turn-on"


def clone_violations(commands):
    """Every `clone` whose destination box is not cleared of BOTH turtle kinds (`fill ... replace computercraft:turtle_normal` and
    `..._advanced`, or `#computercraft:turtle`) by later fills covering that box, before any tick / resume / turn-on. A cloned turtle
    is a copy of a computer: same id, same files, same chunk-loader identity. Returns [(index, command, why)]."""
    out = []
    cmds = [c.strip().lstrip("/") for c in commands]
    for i, text in enumerate(cmds):
        words = text.split()
        if not words or words[0] != "clone":
            continue
        try:
            n = [int(w) for w in words[1:10]]
        except ValueError:
            out.append((i, text, "a clone whose box this check cannot read"))
            continue
        src = _box(n[:6])
        dx, dy, dz = n[6] - src[0], n[7] - src[1], n[8] - src[2]
        dest = (src[0] + dx, src[1] + dy, src[2] + dz, src[3] + dx, src[4] + dy, src[5] + dz)
        cleared = set()
        for later in cmds[i + 1:]:
            w = later.split()
            if not w:
                continue
            if _ticks(w):
                break
            if w[0] == "fill" and len(w) >= 10 and w[8] == "replace":
                try:
                    b = _box([int(v) for v in w[1:7]])
                except ValueError:
                    continue
                if all(b[k] <= dest[k] for k in range(3)) and all(b[k] >= dest[k] for k in range(3, 6)):
                    if w[9] == "#computercraft:turtle":
                        cleared |= set(TURTLE_KINDS)
                    elif w[9] in TURTLE_KINDS:
                        cleared.add(w[9])
            if cleared >= set(TURTLE_KINDS):
                break
        if not cleared >= set(TURTLE_KINDS):
            out.append((i, text, "turtles in the cloned box %s are not removed before the game runs on" % (dest,)))
    return out


def commands_of(interventions):
    """The console commands a Ctx recorded as INTERVENTIONS (args[0] is the repr of the text)."""
    out = []
    for e in interventions:
        if e.get("verb") == "command" and e.get("args"):
            try:
                out.append(ast.literal_eval(e["args"][0]))
            except (ValueError, SyntaxError):
                out.append(str(e["args"][0]))
    return out


# ---------------------------------------------------------------------------------------------------------------------------
# Reading and setting blocks
# ---------------------------------------------------------------------------------------------------------------------------

def _passed(c, pos, spec):
    return "Test passed" in c.command("execute if block %d %d %d %s" % (tuple(pos) + (spec,)))


def is_air(c, pos):
    return any(_passed(c, pos, a) for a in AIR)


def read_block(c, pos, cache=None):
    """(state spec, SNBT without position or None) of the block at pos: the state by BLOCK_CANDIDATES, the NBT by data get."""
    pos = tuple(pos)
    if cache is not None and pos in cache:
        return cache[pos]
    for spec in BLOCK_CANDIDATES:
        if _passed(c, pos, spec):
            break
    else:
        raise UnknownBlock("the block at %s matches none of BLOCK_CANDIDATES; add its id (and state) there rather than guess" % (pos,))
    nbt = None
    if spec not in AIR:
        raw = nbt_of(c.block_data(pos))
        nbt = nbt_without_position(raw) if raw else None
    out = (spec, nbt)
    if cache is not None:
        cache[pos] = out
    return out


def same_block(c, pos, spec, nbt):
    """True when pos already holds that state and that NBT (compared canonically)."""
    if not _passed(c, pos, spec):
        return False
    have = nbt_of(c.block_data(pos)) if nbt is not None else None
    return canonical_nbt(have) == canonical_nbt(nbt)


def set_block(c, pos, spec, nbt=None):
    """setblock with the NBT. Air first when the cell has the same block already: vanilla refuses a setblock to the same state
    ("Could not set the block") and then applies no NBT."""
    x, y, z = pos
    if spec.split("[")[0] not in AIR and _passed(c, pos, spec.split("[")[0]):
        c.command("setblock %d %d %d minecraft:air" % pos)
    out = c.command("setblock %d %d %d %s%s" % (x, y, z, spec, nbt or ""))
    if "Changed the block" not in out:
        raise RuntimeError("setblock %s %s%s -> %r" % (pos, spec, nbt or "", out.strip()[:200]))


# ---------------------------------------------------------------------------------------------------------------------------
# Storage headroom (round 2 ruling): the RS network must not be able to fill by accident
# ---------------------------------------------------------------------------------------------------------------------------

RS_CONTROLLER = (173, 72, -2833)                        # the world copy's RS controller (inside BASE_AREAS, so forceloaded)
RS_CREATIVE_BLOCK = "refinedstorage:creative_storage_block"     # Refined Storage 1.12.4 (mods/refinedstorage-1.12.4.jar): ItemStorageType
                                                         # CREATIVE, capacity -1; creative_storage_disk is its disk twin, but a disk
                                                         # cannot be put into a drive from a console command, a block can be set
RS_NEIGHBOURS = [(1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1), (0, 1, 0), (0, -1, 0)]


RS_COLOURS = ("black", "blue", "brown", "cyan", "gray", "green", "light_blue", "light_gray", "lime", "magenta", "orange", "pink",
              "purple", "red", "white", "yellow")
RS_CONTROLLER_IDS = (["refinedstorage:controller", "refinedstorage:creative_controller"]
                     + ["refinedstorage:%s_controller" % k for k in RS_COLOURS]
                     + ["refinedstorage:%s_creative_controller" % k for k in RS_COLOURS])     # the world has a magenta_controller


def add_rs_capacity(c, controller=RS_CONTROLLER):
    """Sets a creative item storage block on the first free face of the RS controller so that storage cannot fill except as a
    scheduled fault. Idempotent: one already there is kept. Returns {"pos", "placed", "block", "controller": the id read there}.
    Raises when no RS controller of any colour stands at `controller`, or no face is free.
    THE BLOCK DOES NOT JOIN THE NETWORK UNTIL THE WORLD RESTARTS: Refined Storage 1.12.4 discovers a node only on a player's block
    placement event (NetworkNodeListener.onBlockPlace); /setblock fires none, and the network rescans its neighbours only when the
    controller is loaded. So build_world is always followed by restart_after_build (setup and the proof both do it), and capacity
    is read after that."""
    ctrl = next((spec for spec in RS_CONTROLLER_IDS if _passed(c, controller, spec)), None)
    if ctrl is None:
        raise RuntimeError("no Refined Storage controller at %s (tried %d ids): the creative storage block has nothing to join"
                           % (controller, len(RS_CONTROLLER_IDS)))
    faces = [(controller[0] + dx, controller[1] + dy, controller[2] + dz) for dx, dy, dz in RS_NEIGHBOURS]
    for pos in faces:
        if _passed(c, pos, RS_CREATIVE_BLOCK):
            return {"pos": pos, "placed": False, "block": RS_CREATIVE_BLOCK, "controller": ctrl}
    for pos in faces:
        if is_air(c, pos):
            set_block(c, pos, RS_CREATIVE_BLOCK)
            if not _passed(c, pos, RS_CREATIVE_BLOCK):
                raise RuntimeError("the creative storage block at %s did not take" % (pos,))
            return {"pos": pos, "placed": True, "block": RS_CREATIVE_BLOCK, "controller": ctrl}
    raise RuntimeError("no free face next to the RS controller at %s for the creative storage block" % (controller,))


def restart_after_build(ctx):
    """One clean world restart after build_world, BEFORE the fleet is placed: it is what makes the RS network pick up the creative
    storage block (see add_rs_capacity). Afterwards schedule._after_restart, the one after-restart routine every harness restart
    uses (the run's tick rate back; the control mod's radio and event logs on again for --t2logs, since they live in JVM memory;
    ...), instead of a copy of part of it here. Returns what the restart returned."""
    from shakeout import schedule       # here, not at the top: schedule imports this module
    out = ctx.control.world_restart()
    schedule._after_restart(ctx, ctx.control)
    return out


# ---------------------------------------------------------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------------------------------------------------------

def _note(ctx, text):
    if hasattr(ctx, "note"):
        ctx.note(text)


CHEST = "enderstorage:ender_chest"
CC_BLOCKS = ("computercraft:turtle_normal", "computercraft:turtle_advanced", "computercraft:computer_normal",
             "computercraft:computer_advanced", "computercraft:computer_command")
COSMETIC_KEYS = ("rot",)     # which way an ender chest's lid faces: two chests that differ only in it are the same chest


def is_chest(spec):
    return spec.split("[")[0].split("{")[0] == CHEST


def chest_identity(nbt):
    """What makes an under-dock chest the right one: its NBT without position and lid direction (the Frequency, keepPacked...)."""
    return canonical_nbt(nbt, drop=COSMETIC_KEYS)


def under_pos(cell):
    return (cell["x"], cell["y"] - 1, cell["z"])


def under_source(c, cells, cell, cache=None):
    """(source dock, state, NBT, fallback) for the block under a new dock (ruling 2026-11-10): bay 1's dock in the same side, row
    and slot when an ender chest is under it; otherwise the nearest bay-1 dock in the same side and row that has one (nearest by
    slot, the lower slot on a tie). Every shakeout dock gets a chest. Raises when no bay-1 dock in that row has a chest."""
    twin = bay1_twin(cells, cell)
    spec, nbt = read_block(c, under_pos(twin), cache)
    if is_chest(spec):
        return twin, spec, nbt, False
    row = [d for d in cells if d["bay"] == 1 and d["side"] == cell["side"] and d["row"] == cell["row"]]
    for d in sorted(row, key=lambda d: (abs(d["slot"] - cell["slot"]), d["slot"])):
        s, n = read_block(c, under_pos(d), cache)
        if is_chest(s):
            return d, s, n, True
    raise RuntimeError("no ender chest under any bay-1 dock in %s row %s: nothing to copy under %s" % (cell["side"], cell["row"],
                                                                                                    under_pos(cell)))


def under_matches(c, dst, spec, nbt):
    """True when dst already holds that chest: same block, same identity (lid direction aside)."""
    if not _passed(c, dst, spec):
        return False
    return chest_identity(nbt_of(c.block_data(dst))) == chest_identity(nbt)


def _clear(c, pos, comps, report, why, computers_too=True):
    """Makes pos air. A computer standing there is removed and named in report["removed"] when computers_too (dock cells only);
    otherwise it is left standing and named in report["left_standing"]."""
    if is_air(c, pos):
        return False
    cid = comps.get(tuple(pos))
    if not computers_too and (cid is not None or any(_passed(c, pos, k) for k in CC_BLOCKS)):   # not in the dump, still a computer
        report["left_standing"].append({"pos": tuple(pos), "id": cid, "why": why})
        return False
    report["removed"].append({"pos": tuple(pos), "id": cid, "why": why})
    out = c.command("setblock %d %d %d minecraft:air" % tuple(pos))
    if "Changed the block" not in out:
        raise RuntimeError("clearing %s -> %r" % (pos, out.strip()[:200]))
    return True


def _computer_spot_free(c, pos):
    x, y, z = pos
    return is_air(c, (x, y, z)) and is_air(c, (x, y + 1, z))


def _write_startup(text, prefix):
    path = os.path.join(tempfile.mkdtemp(prefix=prefix), "startup.lua")
    with open(path, "w", encoding="utf8", newline="\n") as f:
        f.write(text)
    return path


def _role(c, cid):
    try:
        return (c.role_of(cid) or "").strip().lower()
    except (AttributeError, OSError):
        return ""


def build_world(ctx, cells=None):
    """Builds the shakeout world on a fresh T2 world copy (see the module doc). Returns a report dict; raises UnknownBlock when bay 1
    holds a block it cannot copy faithfully, RuntimeError when the game refuses a change."""
    c = ctx.control
    cells = cells or dock_cells()
    frames = bay_frames(cells)
    report = {"forceload": [], "removed": [], "left_standing": [], "floor": {"set": 0, "same": 0, "chests_kept": []},
              "pillars": {"set": 0, "same": 0}, "under": {"copied": 0, "same": 0, "fallback": 0, "sources": {}, "frequencies": {}},
              "atc": None, "gps": [], "gps_present": [], "gps_blocked": []}

    # 1. Keep the base loaded.
    for area in BASE_AREAS:
        out = c.command("forceload add %d %d %d %d" % area)
        report["forceload"].append((area, out.strip()[:120]))
        if "Marked" not in out and "No chunks were marked" not in out:
            raise RuntimeError("forceload add %s -> %r" % (area, out.strip()[:200]))

    # 2. Empty every dock cell (turtles on docks are removed and named: ONLY there). The rest of the driving level of bays 2-5 is
    #    cleared of plain blocks; a turtle or computer there is left standing and named (Task 5 identifies them).
    comps = {tuple(v["pos"]): k for k, v in c.computers().items()}
    for (side, bay), f in sorted(frames.items()):
        for x, z in sorted(f["docks"]):
            _clear(c, (x, f["y"], z), comps, report, "dock cell")
        if bay == 1:
            continue
        for x in range(f["xs"][0], f["xs"][1] + 1):
            for z in range(f["zs"][0], f["zs"][1] + 1):
                if (x, z) not in f["docks"]:
                    _clear(c, (x, f["y"], z), comps, report, "bay %s %d driving level" % (side, bay), computers_too=False)

    # 3. The floor and the pillar of bays 2-5, from bay 1's.
    cache = {}
    for (side, bay), f in sorted(frames.items()):
        if bay == 1:
            continue
        one = frames[(side, 1)]
        shift = f["centre"] - one["centre"]
        under_docks = {(x - shift, z) for x, z in f["docks"]}
        for x in range(one["xs"][0], one["xs"][1] + 1):
            for z in range(one["zs"][0], one["zs"][1] + 1):
                if (x, z) in under_docks:
                    continue                                  # step 4 copies those, NBT and all
                spec, nbt = read_block(c, (x, f["y"] - 1, z), cache)
                dst = (x + shift, f["y"] - 1, z)
                if same_block(c, dst, spec, nbt):
                    report["floor"]["same"] += 1
                elif not is_chest(spec) and _passed(c, dst, CHEST):
                    report["floor"]["chests_kept"].append(dst)        # a chest is never replaced with floor
                else:
                    set_block(c, dst, spec, nbt)
                    report["floor"]["set"] += 1
        px, pz = one["pillar"]
        for k in range(PILLAR_MAX):
            spec, nbt = read_block(c, (px, f["y"] + k, pz), cache)
            if spec in AIR:
                break
            dst = (px + shift, f["y"] + k, pz)
            if same_block(c, dst, spec, nbt):
                report["pillars"]["same"] += 1
                continue
            if dst in comps or any(_passed(c, dst, k) for k in CC_BLOCKS):
                report["left_standing"].append({"pos": dst, "id": comps.get(dst), "why": "in a pillar cell: pillar not built there"})
                continue
            set_block(c, dst, spec, nbt)
            report["pillars"]["set"] += 1

    # 4. The block under each new dock: an ender chest, copied with its NBT from bay 1's twin, or from the nearest bay-1 dock in the
    #    same row with a chest when the twin has none (ruling 2026-11-10). A cell that already holds the right chest is left alone.
    for cell in cells:
        if cell["bay"] == 1:
            continue
        src, spec, nbt, fallback = under_source(c, cells, cell, cache)
        if not is_chest(spec):
            raise RuntimeError("under-dock source %s is not a chest" % (under_pos(src),))   # under_source never returns one; belt and braces
        report["under"]["fallback"] += 1 if fallback else 0
        report["under"]["sources"][under_pos(cell)] = under_pos(src)
        if frequency_of(nbt or ""):
            report["under"]["frequencies"]["%s row %s slot %d" % (src["side"], src["row"], src["slot"])] = frequency_of(nbt)
        dst = under_pos(cell)
        if under_matches(c, dst, spec, nbt):
            report["under"]["same"] += 1
        else:
            set_block(c, dst, spec, nbt)
            report["under"]["copied"] += 1

    # 5. The ATC computer (once).
    comps = {tuple(v["pos"]): k for k, v in c.computers().items()}
    present = [(p, k) for p, k in comps.items() if _role(c, k) == "atc"]
    if present:
        report["atc"] = {"id": present[0][1], "pos": present[0][0], "placed": False}
    else:
        spot = next((p for p in ATC_CANDIDATES if _computer_spot_free(c, p)), None)
        if spot is None:
            raise RuntimeError("no free ATC spot among %s" % (ATC_CANDIDATES,))
        pin = getattr(ctx, "pin", None) or "HEAD"
        start_text, files = atc_files(pin)
        aid = c.spawn_computer(spot[0], spot[1], spot[2], _write_startup(start_text, "shakeout_atc_"), files=files)
        report["atc"] = {"id": aid, "pos": spot, "placed": True, "pin": pin}
        _note(ctx, "ATC computer #%d placed at %d,%d,%d with atc.lua and %s from %s" % ((aid,) + spot + (", ".join(sorted(files)), pin)))

    # 6. The GPS towers.
    for t in GPS_TOWERS:
        if tuple(t) in comps:
            report["gps_present"].append({"pos": tuple(t), "id": comps[tuple(t)]})
            continue
        if not _computer_spot_free(c, t):
            report["gps_blocked"].append({"pos": tuple(t), "why": "the cell or the one above it is not air"})
            continue
        gid = c.spawn_computer(t[0], t[1], t[2], _write_startup(gps_host_program(t), "shakeout_gps_"))
        report["gps"].append({"pos": tuple(t), "id": gid, "announces": tuple(t)})
    # 7. Storage can only fill as a scheduled fault: one creative item storage block (unlimited capacity) next to the RS controller.
    report["rs_capacity"] = add_rs_capacity(c)
    _note(ctx, "RS capacity: %s" % (report["rs_capacity"],))
    _note(ctx, "shakeout world: %d removed from bay cells, floor set %d / same %d, pillars set %d / same %d, under-dock copied %d / "
          "same %d, GPS towers placed %d, present %d, blocked %d" % (
              len(report["removed"]), report["floor"]["set"], report["floor"]["same"], report["pillars"]["set"],
              report["pillars"]["same"], report["under"]["copied"], report["under"]["same"], len(report["gps"]),
              len(report["gps_present"]), len(report["gps_blocked"])))
    return report


def verify_world(ctx, cells=None):
    """The checks the T2 proof makes after the build, as counts (each can fail): every dock cell air; under every new dock an ender
    chest whose NBT equals its source cell's (under_source: bay 1's twin, or the nearest bay-1 chest in the row), the lid direction
    aside. Returns {"dock_air", "dock_total", "under_ok", "under_total", "under_exact" (NBT equal with the lid direction too),
    "under_fallback", "bad": [what failed]}."""
    c = ctx.control
    cells = cells or dock_cells()
    out = {"dock_air": 0, "dock_total": len(cells), "under_ok": 0, "under_total": 0, "under_exact": 0, "under_fallback": 0, "bad": []}
    for cell in cells:
        pos = (cell["x"], cell["y"], cell["z"])
        if is_air(c, pos):
            out["dock_air"] += 1
        else:
            out["bad"].append("dock cell %s is not air" % (pos,))
    for cell in cells:
        if cell["bay"] == 1:
            continue
        out["under_total"] += 1
        src, spec, nbt, fallback = under_source(c, cells, cell)
        out["under_fallback"] += 1 if fallback else 0
        dst = under_pos(cell)
        have = nbt_of(c.block_data(dst))
        if is_chest(spec) and _passed(c, dst, spec) and nbt is not None and chest_identity(have) == chest_identity(nbt):
            out["under_ok"] += 1
            out["under_exact"] += 1 if canonical_nbt(have) == canonical_nbt(nbt) else 0
        else:
            out["bad"].append("under %s: want %s %s (from %s), have %s" % (dst, spec, nbt, under_pos(src), have))
    return out


def save_point(ctx, name):
    """The control verb (save-all, then a copy of the world folder under <run>/savepoints/<name>), recorded as an intervention."""
    return ctx.control.save_point(name)
