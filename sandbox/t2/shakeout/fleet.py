"""Shakeout fleet placement (plan Task 5; spec section 4.2.5): 160 FRESH turtles, each already standing in the dock the
dispatch server will have for it.

    from shakeout import fleet
    placed = fleet.place_fleet(ctx)          # {node_id: dock cell}; also seeds the server's dock_assignments.dat
    fleet.read_role_kit(ctx, fleet.KIT_SOURCES), fleet.kit_differences(fleet.ROLE_KIT, read)   # the kit, checked on T2

What place_fleet does, in order:
  1. refuses unless every dock cell is empty (world.build_world empties them) and finds a free loader staging cell;
  2. switches the dispatch computer OFF, so the seed below is what it reads when it boots (it reads dock_assignments.dat
     once, at start: waypoints.loadDockAssignments);
  3. for each dock cell, in waypoints.lua's own order: for a miner first a FRESH loader (below), then the turtle itself with
     Control.spawn_turtle: a new advanced turtle with its own new computer id, the role's code copied from a donor of the
     same role (code only: control.is_state_file keeps every journal, log and save behind), the role's upgrade, fuel and slot
     items from ROLE_KIT, NBT included (the ender chests' frequencies);
  4. writes dock_assignments.dat into the dispatch computer's disk folder in the format waypoints.lua saves and reads: byPos
     ("x,z" -> node id, what the server reads back) and the typed lists beside it, as saveDockAssignments writes them. The
     world copy's old file (old nodes on old docks) is replaced whole;
  5. switches the dispatch computer back on.

A FRESH LOADER (spec 4.2.5, memory "copied turtles share a chunk ticket"): a loader is an advanced turtle carried as an item,
and the item names the computer it is (ComputerId) and the chunky upgrade's identity (RightUpgradeNbt.uuid). Two items with the
same uuid hold ONE ticket between them. So each miner's loader is made new: a turtle block with a modem and a chunky upgrade is
set at a staging cell with On:1b (that is what gives it a computer id: the game picks it), switched off at once, given the
loader code (role LOADER, from the donor loader, or from the pinned commit when the run has one), and removed again; the item
the miner carries is ROLE_KIT's loader item with every identity tag stripped (strip_identity) and that new ComputerId and a
label after it, loader_<id>, the way the world's own loaders are labelled. No RightUpgradeNbt: the chunky upgrade makes itself
a new uuid when the loader is first placed. Nothing is copied from another loader but its code.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
T2 = os.path.dirname(HERE)
if T2 not in sys.path:
    sys.path.insert(0, T2)
import control as ctl  # noqa: E402
import run as runmod  # noqa: E402
from shakeout import world  # noqa: E402

# ---------------------------------------------------------------------------------------------------------------------------
# What each role carries
# ---------------------------------------------------------------------------------------------------------------------------

LOADER_ITEM = "computercraft:turtle_advanced"
LOADER_UPGRADE = "advancedperipherals:chunky_turtle"
MODEM_UPGRADE = "computercraft:wireless_modem_advanced"

# Read OFFLINE from the world copy every T2 run starts from (phase0.WORLD, worlds/unpacked/2026-10-18_1700: its region files'
# turtle block entities, through sandbox/tools/import_world.py's scan, cached in worlds/2026-10-18_1700/sim/fleet_scan.json),
# one turtle of each role, copied as it is except the loader item's identity (see strip_identity). Items are keyed by NBT
# slot, 0-15: NBT slot n is Lua slot n + 1. `right` is the upgrade on the side that is not the modem (every one of them has
# computercraft:wireless_modem_advanced, active, on the other side). On T2 the scenario reads the same turtles again with
# get_slot (read_role_kit) and fails a check if anything here differs (kit_differences).
#   DELIVERY  #96 at 153,67,-2806 (worker bay 1). Its siblings #102, #109 carry the same; #103's fuel chest has no tag
#             (the default frequency 0,0,0, the same chest).
#   SUPPORT   #143 at 156,67,-2793 (support bay 1): nothing in its slots. Others carry left-over coal from jobs; not kit.
#   MINER     #183 at 167,67,-2806 (worker bay 2): geo scanner, its loader (#195, labelled loader_195), the stowed pickaxe, the
#             fuel chest (0,0,0, the frequency under every dock) and the ore chest (0,1,0). Miners #182 and #178 carry the
#             same; #179 and #181 have their two upgrades on swapped sides (the equipment swap dance), same items.
ROLE_KIT = {
    "DELIVERY": {"right": "minecraft:diamond_pickaxe", "fuel": 97421,
                 "items": {14: ("enderstorage:ender_chest", 1, "{Frequency:{left:0,middle:0,right:0}}"),
                           15: ("enderstorage:ender_chest", 1, "{Frequency:{left:0,middle:10,right:0}}")}},
    "SUPPORT": {"right": LOADER_UPGRADE, "fuel": 99624, "items": {}},
    "MINER": {"right": LOADER_UPGRADE, "fuel": 98299, "loader_slot": 1,
              "items": {0: ("advancedperipherals:geo_scanner", 1, None),
                        1: (LOADER_ITEM, 1, '{LeftUpgrade:"%s",RightUpgrade:"%s"}' % (MODEM_UPGRADE, LOADER_UPGRADE)),
                        2: ("minecraft:diamond_pickaxe", 1, "{Damage:0}"),
                        14: ("enderstorage:ender_chest", 1, "{Frequency:{left:0,middle:0,right:0}}"),
                        15: ("enderstorage:ender_chest", 1, "{Frequency:{left:0,middle:1,right:0}}")}},
}
KIT_SOURCES = {"DELIVERY": 96, "SUPPORT": 143, "MINER": 183}   # the computers ROLE_KIT was read from
LOADER_SOURCE = 195                                            # the loader #183 carries: the code donor for new loaders

# Where a new loader stands for the moment it takes to get an id: in the air over the building's north-west corner, inside
# BASE_AREAS (force-loaded), above no dock, lane or tower (GPS_TOWERS are at y 95+ there; the roof is y 85-87).
LOADER_STAGING = [(134, 90, z) for z in range(-2846, -2830, 2)]

# Tags that make an item a particular computer or a particular chunk-loading identity: never carried over to a new one.
IDENTITY_KEYS = ("ComputerId", "display", "Label")
UPGRADE_NBT_KEYS = ("RightUpgradeNbt", "LeftUpgradeNbt")
DOCK_FILE = "dock_assignments.dat"
DOCK_TYPES = ("DELIVERY", "SUPPORT", "MINER")


def is_state_file(name):
    return ctl.is_state_file(name)


def canonical(tag):
    """A tag's SNBT in one comparable form (compound keys sorted, no spaces outside strings); None stays None."""
    return world._dump(world.parse_snbt(tag), sort=True) if tag else None


def strip_identity(tag):
    """The item tag without what makes it ONE computer or ONE chunk ticket: ComputerId, its label (display / Label), and an
    upgrade NBT holding a uuid (the chunky upgrade's identity). Everything else is kept as it is."""
    v = world.parse_snbt(tag)
    keep = []
    for k, x in v[1]:
        if k in IDENTITY_KEYS:
            continue
        if k in UPGRADE_NBT_KEYS and "uuid" in world._dump(x):
            continue
        keep.append((k, x))
    return world._dump(("c", keep))


def loader_tag(kit_tag, cid):
    """The item tag of a new loader: the kit's loader tag stripped of identity, plus its own computer id and label."""
    base = strip_identity(kit_tag)
    extra = "ComputerId:%d,display:{Name:'{\"text\":\"loader_%d\"}'}" % (cid, cid)
    return base[:-1] + ("," if base != "{}" else "") + extra + "}"


# ---------------------------------------------------------------------------------------------------------------------------
# Finding the server and the donors
# ---------------------------------------------------------------------------------------------------------------------------

def server_computer(ctx):
    """The RUNNING dispatch computer: the last 'Central server online ... ID: node_NNN' line (w3_low_disk.py: a scan of disks
    found a stray SERVER disk, #110, not the running #95)."""
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def find_donors(ctx):
    """{role: computer id} of a REGISTERED turtle per role (registered nodes are the ones a --pin updated), KIT_SOURCES first."""
    reg = {}
    for node, t in sorted((ctx.state().get("turtles") or {}).items()):
        role = (t.get("role") or "").upper()
        try:
            reg.setdefault(role, []).append(int(node.replace("node_", "")))
        except ValueError:
            continue
    out = {}
    for role in DOCK_TYPES:
        ids = reg.get(role, [])
        if KIT_SOURCES[role] in ids:
            out[role] = KIT_SOURCES[role]
        elif ids:
            out[role] = ids[0]
    return out


def _game_s(ctx):
    try:
        return ctx.game_seconds()
    except Exception:  # noqa: BLE001 - a fake ctx, or the server between answers: the record still goes in
        return 0


def record(ctx, verb, *args, **kwargs):
    """An INTERVENTION that is not a Control call (a file written into a computer's disk folder, a process started)."""
    ctx.interventions.append({"verb": verb, "args": [repr(a) for a in args], "kwargs": {k: repr(v) for k, v in kwargs.items()},
                              "game_seconds": _game_s(ctx)})


# ---------------------------------------------------------------------------------------------------------------------------
# Code onto a disk
# ---------------------------------------------------------------------------------------------------------------------------

def _git_show(sha, name):
    try:
        return subprocess.run(["git", "-C", runmod.REPO, "show", "%s:%s" % (sha, name)], capture_output=True, check=True).stdout
    except subprocess.CalledProcessError:
        return None


def install_code(ctx, cid, donor, role, pin=None):
    """A computer's code: the donor's files that are not state (control.is_state_file), then -- when the run is pinned -- each
    .lua the commit has, and startup.lua as the commit's file for the role (what run.install_at does to a whole world).
    Returns the file names written."""
    c = ctx.control
    src = os.path.join(c.disks, str(donor))
    dest = os.path.join(c.disks, str(cid))
    os.makedirs(dest, exist_ok=True)
    names = []
    for name in sorted(os.listdir(src)):
        path = os.path.join(src, name)
        if not os.path.isfile(path) or is_state_file(name):
            continue
        data = None
        if pin:
            data = _git_show(pin, runmod.STARTUP_SRC[role]) if name == "startup.lua" else (_git_show(pin, name) if name.endswith(".lua") else None)
        if data is None:
            with open(path, "rb") as f:
                data = f.read()
        with open(os.path.join(dest, name), "wb") as f:
            f.write(data)
        names.append(name)
    record(ctx, "write_disk", cid, "code of #%d%s" % (donor, " at " + pin[:12] if pin else ""), files=names)
    return names


def _new_computer_at(c, pos, before, tries=20):
    for _ in range(tries):
        for cid, v in c.computers().items():
            if cid not in before and tuple(v["pos"]) == tuple(pos):
                return cid
        time.sleep(1)
    raise RuntimeError("no new computer appeared at %s" % (pos,))


def make_loader(ctx, spot, donor, pin=None):
    """A fresh loader's computer (see the module doc): placed at `spot` with On:1b so the game gives it an id, switched off,
    given the loader code, and removed, leaving its disk folder. Returns its computer id."""
    c = ctx.control
    x, y, z = spot
    before = set(c.computers())
    out = c.command('setblock %d %d %d %s[facing=north]{LeftUpgrade:"%s",LeftUpgradeNbt:{active:1b},RightUpgrade:"%s",On:1b}'
                    % (x, y, z, LOADER_ITEM, MODEM_UPGRADE, LOADER_UPGRADE))
    if "Changed the block" not in out:
        raise RuntimeError("placing a new loader at %s -> %r" % (spot, out.strip()[:200]))
    cid = _new_computer_at(c, spot, before)
    c.shutdown([cid])
    install_code(ctx, cid, donor, "LOADER", pin)
    out = c.command("setblock %d %d %d minecraft:air" % spot)
    if "Changed the block" not in out:
        raise RuntimeError("removing new loader #%d from %s -> %r" % (cid, spot, out.strip()[:200]))
    return cid


# ---------------------------------------------------------------------------------------------------------------------------
# The dock file
# ---------------------------------------------------------------------------------------------------------------------------

def dock_seed_text(placed, layout):
    """dock_assignments.dat as waypoints.saveDockAssignments writes it (textutils.serialise's layout): byPos ("x,z" -> node id),
    which is what loadDockAssignments reads, and each type's list by its index in W.docks (dock_cells' order is that order)."""
    index, n = {}, {}
    for cell in layout:
        t = cell["type"]
        n[t] = n.get(t, 0) + 1
        index[(cell["x"], cell["z"])] = (t, n[t])
    by_pos, typed = [], {}
    for node, cell in sorted(placed.items(), key=lambda kv: (kv[1]["x"], kv[1]["z"])):
        t, i = index[(cell["x"], cell["z"])]
        by_pos.append('    [ "%d,%d" ] = "%s",' % (cell["x"], cell["z"], node))
        typed.setdefault(t, {})[i] = node
    out = ["{", "  byPos = {"] + by_pos + ["  },"]
    for t in DOCK_TYPES:
        slots = typed.get(t)
        if not slots:
            continue
        if sorted(slots) == list(range(1, len(slots) + 1)):
            out += ["  %s = {" % t] + ['    "%s",' % slots[i] for i in sorted(slots)] + ["  },"]
        else:
            out += ["  %s = {" % t] + ['    [ %d ] = "%s",' % (i, slots[i]) for i in sorted(slots)] + ["  },"]
    return "\n".join(out) + "\n}"


# ---------------------------------------------------------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------------------------------------------------------

def _write_seed(ctx, c, sid, placed, layout, partial=False):
    with open(os.path.join(c.disks, str(sid), DOCK_FILE), "w", encoding="utf8", newline="\n") as f:
        f.write(dock_seed_text(placed, layout))
    record(ctx, "write_disk", sid, DOCK_FILE, entries=len(placed), partial=partial)
    if partial and hasattr(ctx, "note"):
        ctx.note("shakeout fleet: placement stopped part-way; %s seeded with the %d turtles placed so far" % (DOCK_FILE, len(placed)))


def place_fleet(ctx, layout=None, kit=None, donors=None, server_id=None, loader_donor=None, staging=None):
    """Places the fleet (see the module doc). Returns {node_id: dock cell}; ctx.shakeout_fleet keeps the server id, the
    placement and each miner's loader id for the fault scheduler and the checks."""
    c = ctx.control
    layout = layout or world.dock_cells()
    kit = kit or ROLE_KIT
    sid = server_id or server_computer(ctx)
    if sid is None:
        raise RuntimeError("place_fleet: no running dispatch computer found ('Central server online' never logged)")
    donors = donors or find_donors(ctx)
    missing = [t for t in sorted({cell["type"] for cell in layout}) if t not in donors]
    if missing:
        raise RuntimeError("place_fleet: no donor computer for %s" % missing)
    loader_donor = loader_donor or LOADER_SOURCE
    occupied = [cell for cell in layout if not world.is_air(c, (cell["x"], cell["y"], cell["z"]))]
    if occupied:
        raise RuntimeError("place_fleet needs every dock cell empty (world.build_world empties them); occupied: %s"
                           % ", ".join("%d,%d,%d" % (cl["x"], cl["y"], cl["z"]) for cl in occupied[:20]))
    needs_loader = any("loader_slot" in kit[cell["type"]] for cell in layout)
    spot = staging or next((p for p in LOADER_STAGING if world.is_air(c, p)), None)
    if needs_loader and spot is None:
        raise RuntimeError("place_fleet: no free loader staging cell among %s" % (LOADER_STAGING,))
    pin = getattr(ctx, "pin", None) or getattr(ctx, "install", None)

    c.shutdown([sid])
    placed, loaders = {}, {}
    seeded = False
    try:
        for cell in layout:
            role = cell["type"]
            k = kit[role]
            items = dict(k["items"])
            lid = None
            if "loader_slot" in k:
                lid = make_loader(ctx, spot, loader_donor, pin)
                item, count, tag = items[k["loader_slot"]]
                items[k["loader_slot"]] = (item, count, loader_tag(tag, lid))
            cid = c.spawn_turtle(cell["x"], cell["y"], cell["z"], role, fuel=k["fuel"], facing=cell["facing"], donor=donors[role],
                                 right=k["right"], items=items, start=False)
            node = "node_%d" % cid
            placed[node] = dict(cell)
            if lid is not None:
                loaders[node] = lid
            # checked while it is still OFF: what is on its disk now came from the donor, not from its own first boot
            stale = [f for f in c.list_disk(cid) if is_state_file(f)]
            if stale:
                raise RuntimeError("%s was given state files %s: it is not fresh" % (node, stale))
            c.turn_on([cid])
        _write_seed(ctx, c, sid, placed, layout)
        seeded = True
    finally:
        # A placement that fails part-way must not leave the dispatch computer off, nor with the world copy's old file:
        # the turtles placed so far are seeded where they stand, and the server comes back either way.
        if not seeded and placed:
            try:
                _write_seed(ctx, c, sid, placed, layout, partial=True)
            except Exception as ex:  # noqa: BLE001 - the original error is the one to raise
                if hasattr(ctx, "note"):
                    ctx.note("shakeout fleet: the partial dock seed could not be written: %s" % ex)
        c.turn_on([sid])
        ctx.shakeout_fleet = {"server": sid, "placed": placed, "loaders": loaders, "donors": dict(donors),
                              "loader_donor": loader_donor, "complete": seeded}
    if hasattr(ctx, "note"):
        counts = {}
        for cell in placed.values():
            counts[cell["type"]] = counts.get(cell["type"], 0) + 1
        ctx.note("shakeout fleet: placed %s fresh turtles (%s), %d fresh loaders; donors %s, loader donor #%s%s; %s seeded on #%d"
                 % (len(placed), ", ".join("%s %d" % kv for kv in sorted(counts.items())), len(loaders), donors, loader_donor,
                    " (code at %s)" % pin if pin else "", DOCK_FILE, sid))
    return placed


FLEET_ROLES = ("DELIVERY", "SUPPORT", "MINER", "LOADER")


def retire_strays(ctx, keep=()):
    """Removes every loaded computer with a fleet role (DELIVERY, SUPPORT, MINER, LOADER) that is not in `keep` (computer ids),
    so the run has exactly the placed fleet: the world copy has a miner out in the field (#178 at 839,200,-2813 in the
    2026-10-18 copy) that build_world, which clears dock cells only, leaves standing; it would register as a 161st turtle and
    find no free MINER dock. Each is switched off, then its block set to air (its disk folder stays: a donor's code survives).
    Turtles with NO role -- the copy's six unconfigured miner bodies at x 164-165 between bays 1 and 2, fuel 0, empty disks
    (#130-137), and its probe computers (#147, #148, #158) -- are not fleet nodes and are left alone. Returns [(id, pos, role)]."""
    c = ctx.control
    keep = set(keep)
    out = []
    for cid, v in sorted(c.computers().items()):
        role = (c.role_of(cid) or "").strip().upper()
        if cid in keep or role not in FLEET_ROLES:
            continue
        pos = tuple(v["pos"])
        c.shutdown([cid])
        r = c.command("setblock %d %d %d minecraft:air" % pos)
        if "Changed the block" not in r:
            raise RuntimeError("retiring #%d (%s) at %s -> %r" % (cid, role, pos, r.strip()[:200]))
        out.append((cid, pos, role))
    if out and hasattr(ctx, "note"):
        ctx.note("shakeout fleet: retired %d fleet computers not part of the shakeout: %s" % (
            len(out), ", ".join("#%d %s at %d,%d,%d" % ((i, r) + p) for i, p, r in out)))
    return out


# ---------------------------------------------------------------------------------------------------------------------------
# Reading the kit back on T2
# ---------------------------------------------------------------------------------------------------------------------------

def _value(reply):
    return reply.split("data: ", 1)[-1].strip() if "data: " in reply else None


def parse_stack(text):
    """(item id, count, tag SNBT or None) of a stack as `data get` prints it."""
    v = dict(world.parse_snbt(text)[1])
    item = v["id"][1].strip("\"'")
    count = int(v["Count"][1].rstrip("bB"))
    tag = world._dump(v["tag"]) if "tag" in v else None
    return item, count, tag


def read_role_kit(ctx, ids):
    """{role: {"right", "fuel", "items": {slot: (item, count, tag)}}} read from the game: get_slot for every slot, the fuel,
    and the upgrade on whichever side is not the modem."""
    c = ctx.control
    comps = c.computers()
    out = {}
    for role, cid in ids.items():
        pos = tuple(comps[cid]["pos"])
        ups = [(_value(c.block_data(pos, side)) or "").strip("\"'") for side in ("RightUpgrade", "LeftUpgrade")]
        right = next((u for u in ups if u and u != MODEM_UPGRADE), None)
        items = {}
        for slot in range(16):
            text = c.get_slot(cid, slot)
            if "Found no elements" in text:
                continue
            items[slot] = parse_stack(text)
        out[role] = {"right": right, "fuel": c.get_fuel(cid), "items": items}
    return out


def kit_differences(want, got):
    """What differs between two kits, slot by slot (fuel is not compared: it is noted, not kit). A loader item is compared
    without its identity tags (strip_identity), since each one has its own."""
    out = []
    for role in sorted(want):
        if role not in got:
            out.append("%s: not read" % role)
            continue
        w, g = want[role], got[role]
        if w["right"] != g["right"]:
            out.append("%s upgrade: kit %s, game %s" % (role, w["right"], g["right"]))
        for slot in sorted(set(w["items"]) | set(g["items"])):
            a, b = w["items"].get(slot), g["items"].get(slot)
            if a is None or b is None:
                out.append("%s slot %d: kit %s, game %s" % (role, slot, a, b))
                continue
            strip = (lambda t: canonical(strip_identity(t)) if t else None) if slot == w.get("loader_slot") else canonical
            if (a[0], a[1], strip(a[2])) != (b[0], b[1], strip(b[2])):
                out.append("%s slot %d: kit %s, game %s" % (role, slot, a, b))
    return out
