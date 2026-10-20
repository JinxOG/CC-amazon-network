"""Imports a Minecraft server world copy into the sandbox's own world format.

usage:
  python sandbox/tools/import_world.py <unpacked_world_dir> --out <dir>
         [--storage <state.json>] [--area x1,z1,x2,z2 ...] [--margin N] [--rescan]

What it reads (all read-only; it never writes into the world copy, and it makes NO network call of any kind):
  region/*.mca                 blocks of the chunks that matter, and every computer / turtle block entity
  computercraft/computer/<id>  every computer's disk, copied to <out>/disks/<id>
  EnderStorage/*.dat           ender chest contents by frequency
  --storage <state.json>       a saved copy of the live bridge's /state; its `storage` list becomes the RS contents

What it writes under --out:
  meta.lua  chunks/<cx>_<cz>.txt     the sandbox World (core format; runs of blocks up a column)
  fleet.json                         every fleet computer and turtle: position, facing, fuel, inventory, upgrades
  storage.json  ender.json           Refined Storage contents; ender chest frequencies and contents
  disks/<id>/                        computer disks
  fleet_scan.json                    cache of the whole-world search for computers (slow; reused unless --rescan)

Findings about the real layout (checked on the 2026-10-18 17:00 backup, Minecraft 1.20.1):
  * computers/turtles are block entities in the region files: ids computercraft:{turtle,computer}_{normal,advanced},
    with ComputerId, Fuel, Items (Slot is 0-based), LeftUpgrade/RightUpgrade, On; labels are NOT in the block entity
    (they are stored on the computer's disk side, so nodes are named node_<ComputerId> unless a label is found).
  * an ender chest's frequency is {left, middle, right} colour numbers; the same triple is on the item's tag.Frequency.
  * peripherals are blocks beside the computer (rs_bridge, wireless_modem_advanced, cloudsolutions:kv_storage ...).
  * the computer's `facing` is in the block state of its block (palette Properties).
"""
import argparse
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nbt  # noqa: E402

MIN_Y = -64

CC_IDS = {
    "computercraft:turtle_normal": ("turtle", False), "computercraft:turtle_advanced": ("turtle", True),
    "computercraft:computer_normal": ("computer", False), "computercraft:computer_advanced": ("computer", True),
    "computercraft:computer_command": ("computer", True),
}

# Blocks a turtle can pass through, or that are not blocks the fleet cares about: left out of the sandbox world.
NOT_SOLID_EXACT = {
    "minecraft:water", "minecraft:lava", "minecraft:bubble_column", "minecraft:kelp", "minecraft:kelp_plant",
    "minecraft:seagrass", "minecraft:tall_seagrass", "minecraft:grass", "minecraft:tall_grass", "minecraft:fern",
    "minecraft:large_fern", "minecraft:dead_bush", "minecraft:vine", "minecraft:snow", "minecraft:light",
    "minecraft:structure_void", "minecraft:barrier_never",
}
NOT_SOLID_WORDS = ("sapling", "dandelion", "poppy", "tulip", "orchid", "allium", "azure_bluet", "oxeye", "cornflower",
                   "lily_of_the_valley", "torch", "short_grass", "flower", "tallgrass", "wheat", "sweet_berry")


# A turtle's upgrade is stored under the upgrade's id, but turtle.getEquippedLeft/Right report the ITEM name
# (and the fleet compares against that). Only the chunky upgrade differs; the modem and pickaxe use one name for both.
UPGRADE_TO_ITEM = {"advancedperipherals:chunky_turtle": "advancedperipherals:chunk_controller"}


def upgrade_item(upgrade_id):
    return UPGRADE_TO_ITEM.get(upgrade_id, upgrade_id)


def is_not_solid(name):
    return name in NOT_SOLID_EXACT or any(w in name for w in NOT_SOLID_WORDS)


def frequency_key(freq):
    """EnderStorage frequency {left, middle, right} -> '<left>,<middle>,<right>'."""
    if not isinstance(freq, dict):
        return "default"
    return f"{freq.get('left', 0)},{freq.get('middle', 0)},{freq.get('right', 0)}"


def item_name_text(tag):
    """The visible name of an item stack, or None. display.Name is a JSON text component."""
    try:
        raw = tag["display"]["Name"]
    except (KeyError, TypeError):
        return None
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj.get("text") or (obj.get("extra") or [{}])[0].get("text")
        return str(obj)
    except Exception:
        return raw


def convert_stack(item):
    """An NBT inventory entry -> the sandbox's stack table (slot is 1-based)."""
    stack = {"slot": item["Slot"] + 1, "name": item["id"], "count": item.get("Count", 1)}
    tag = item.get("tag") or {}
    if "Frequency" in tag:
        stack["frequency"] = frequency_key(tag["Frequency"])
    if "ComputerId" in tag:
        stack["computer_id"] = tag["ComputerId"]
    label = item_name_text(tag)
    if label:
        stack["displayName"] = label
    elif "Label" in tag:
        stack["displayName"] = tag["Label"]
    for side in ("LeftUpgrade", "RightUpgrade"):
        if side in tag:
            stack[side] = upgrade_item(tag[side])
    if "Fuel" in tag:
        stack["fuel"] = tag["Fuel"]
    return stack


def region_files(world):
    d = os.path.join(world, "region")
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".mca"))


def block_state_at(chunk, x, y, z):
    """The palette entry (Name + Properties) of the block at world position x, y, z inside `chunk`."""
    sy = y // 16
    for section in chunk.get("sections", []):
        if section.get("Y") != sy:
            continue
        bs = section.get("block_states") or {}
        palette = bs.get("palette") or []
        if not palette:
            return None
        idx = nbt.section_indices(section)
        if idx is None:
            return palette[0]
        return palette[idx[(y % 16) * 256 + (z % 16) * 16 + (x % 16)]]
    return None


def scan_fleet(world, cache_path, rescan):
    """Every computercraft computer/turtle block entity in the world (a slow, one-off walk of all regions)."""
    if os.path.exists(cache_path) and not rescan:
        with open(cache_path, "r", encoding="utf-8") as f:
            return json.load(f)
    found = []
    unreadable = []
    files = region_files(world)
    for i, path in enumerate(files):
        reg = nbt.Region(path)
        for cx, cz in reg.present():
            try:
                chunk = reg.chunk(cx, cz)
            except Exception as e:  # a damaged chunk in the backup: note it and go on
                unreadable.append({"chunk": [cx, cz], "region": os.path.basename(path), "error": str(e)})
                continue
            if not chunk:
                continue
            for be in chunk.get("block_entities", []):
                if be.get("id") in CC_IDS:
                    state = block_state_at(chunk, be["x"], be["y"], be["z"])
                    be = dict(be)
                    be["_facing"] = ((state or {}).get("Properties") or {}).get("facing")
                    be["_chunk"] = [cx, cz]
                    found.append(be)
        if (i + 1) % 10 == 0 or i + 1 == len(files):
            print(f"  scanned {i + 1}/{len(files)} regions, {len(found)} computers so far", file=sys.stderr)
    if unreadable:
        print(f"  {len(unreadable)} damaged chunks skipped (listed in fleet_scan_unreadable.json)", file=sys.stderr)
        with open(os.path.join(os.path.dirname(cache_path), "fleet_scan_unreadable.json"), "w", encoding="utf-8") as f:
            json.dump(unreadable, f, indent=1)
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(found, f)
    return found


FACING = {"north": 0, "east": 1, "south": 2, "west": 3}
DELTA = {0: (0, -1), 1: (1, 0), 2: (0, 1), 3: (-1, 0)}


def side_names(facing):
    """Neighbour offsets (dx, dy, dz) -> CC side name for a computer facing `facing` (0 north, 1 east ...)."""
    out = {(0, 1, 0): "top", (0, -1, 0): "bottom"}
    for turn, side in ((0, "front"), (1, "right"), (2, "back"), (3, "left")):
        dx, dz = DELTA[(facing + turn) % 4]
        out[(dx, 0, dz)] = side
    return out


def lua_value(v, indent=""):
    """Plain Lua source for a JSON-like value, keys sorted (the sandbox's luaser format)."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(int(v)) if float(v).is_integer() else repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'
    if v is None:
        return "nil"
    if isinstance(v, (list, tuple)):
        inner = "".join(f"{indent}  [{i + 1}] = {lua_value(x, indent + '  ')},\n" for i, x in enumerate(v))
        return "{\n" + inner + indent + "}"
    if isinstance(v, dict):
        keys = sorted(v.keys(), key=lambda k: (isinstance(k, str), k))
        inner = "".join(f"{indent}  [{lua_value(k)}] = {lua_value(v[k], indent + '  ')},\n" for k in keys)
        return "{\n" + inner + indent + "}"
    raise TypeError(type(v))


def runs_for_chunk(chunk):
    """Lines of the sandbox chunk file: 'r<TAB>lx<TAB>lz<TAB>y0<TAB>y1<TAB>name' runs of one block up a column."""
    columns = {}
    for lx, y, lz, entry in nbt.chunk_blocks(chunk):
        name = entry["Name"]
        if is_not_solid(name):
            continue
        columns.setdefault((lx, lz), []).append((y, name))
    lines = []
    for (lx, lz), blocks in sorted(columns.items()):
        blocks.sort()
        y0 = prev = blocks[0][0]
        cur = blocks[0][1]
        for y, name in blocks[1:]:
            if name == cur and y == prev + 1:
                prev = y
                continue
            lines.append(f"r\t{lx}\t{lz}\t{y0}\t{prev}\t{cur}\n")
            y0, prev, cur = y, y, name
        lines.append(f"r\t{lx}\t{lz}\t{y0}\t{prev}\t{cur}\n")
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("world")
    ap.add_argument("--out", required=True)
    ap.add_argument("--storage")
    ap.add_argument("--area", action="append", default=[], help="x1,z1,x2,z2 in blocks; may be given several times")
    ap.add_argument("--margin", type=int, default=1, help="extra chunks around every computer / area (default 1)")
    ap.add_argument("--rescan", action="store_true", help="search the whole world for computers again")
    ap.add_argument("--scan-cache", help="reuse (or write) this whole-world computer search instead of <out>/fleet_scan.json")
    args = ap.parse_args()

    world, out = os.path.abspath(args.world), os.path.abspath(args.out)
    if out.startswith(world):
        sys.exit("refusing to write inside the world copy")
    os.makedirs(os.path.join(out, "chunks"), exist_ok=True)
    os.makedirs(os.path.join(out, "disks"), exist_ok=True)

    print("1. finding every computer and turtle ...", file=sys.stderr)
    computers = scan_fleet(world, args.scan_cache or os.path.join(out, "fleet_scan.json"), args.rescan)

    # fleet members: computers that have a disk with a program (startup.lua) in the world copy
    disk_root = os.path.join(world, "computercraft", "computer")
    fleet, skipped = [], []
    for be in computers:
        cid = be.get("ComputerId")
        d = os.path.join(disk_root, str(cid))
        kind, advanced = CC_IDS[be["id"]]
        if cid is None or not os.path.isdir(d) or not os.path.exists(os.path.join(d, "startup.lua")):
            skipped.append({"id": cid, "reason": "no disk with a startup program", "pos": [be["x"], be["y"], be["z"]]})
            continue
        role = None
        for rf in ("role.txt", ".role"):
            p = os.path.join(d, rf)
            if os.path.exists(p):
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    role = f.read().strip().lower() or None
                break
        spec = {
            "id": cid, "kind": kind, "role": role, "installed": True,
            "pos": {"x": be["x"], "y": be["y"], "z": be["z"], "facing": FACING.get(be.get("_facing") or "north", 0)},
            "on": bool(be.get("On", 0)),
        }
        if kind == "turtle":
            inv = {}
            carried = []
            for item in be.get("Items", []):
                stack = convert_stack(item)
                slot = stack.pop("slot")
                inv[slot] = stack
                if stack["name"].startswith("computercraft:turtle") and "computer_id" in stack:
                    carried.append(stack)
            spec["turtle"] = {"fuel": be.get("Fuel", 0), "inv": inv,
                              "equipped": {k: upgrade_item(be[v]) for k, v in (("left", "LeftUpgrade"), ("right", "RightUpgrade")) if v in be}}
            spec["carried_items"] = carried
        fleet.append(spec)

    # computers carried as items (the loaders inside a miner's pack) need their own entries
    known = {s["id"] for s in fleet}
    for spec in list(fleet):
        for stack in spec.get("carried_items", []):
            cid = stack["computer_id"]
            if cid in known:
                continue
            d = os.path.join(disk_root, str(cid))
            if not os.path.isdir(d):
                continue
            known.add(cid)
            role = None
            for rf in ("role.txt", ".role"):
                p = os.path.join(d, rf)
                if os.path.exists(p):
                    with open(p, "r", encoding="utf-8", errors="replace") as f:
                        role = f.read().strip().lower() or None
                    break
            fleet.append({"id": cid, "kind": "turtle", "role": role, "installed": True, "carried": True,
                          "label": stack.get("displayName"),
                          "turtle": {"fuel": stack.get("fuel", 0), "inv": {},
                                     "equipped": {"left": upgrade_item(stack.get("LeftUpgrade")), "right": upgrade_item(stack.get("RightUpgrade"))}}})
    for spec in fleet:
        spec.pop("carried_items", None)

    print(f"   {len(fleet)} fleet computers, {len(skipped)} skipped (no program on their disk)", file=sys.stderr)

    # chunks that matter
    wanted = set()

    def add_chunk_box(x1, z1, x2, z2, margin):
        cx1, cx2 = min(x1, x2) // 16 - margin, max(x1, x2) // 16 + margin
        cz1, cz2 = min(z1, z2) // 16 - margin, max(z1, z2) // 16 + margin
        for cx in range(cx1, cx2 + 1):
            for cz in range(cz1, cz2 + 1):
                wanted.add((cx, cz))

    for spec in fleet:
        p = spec.get("pos")
        if not spec.get("carried") and p:
            add_chunk_box(p["x"], p["z"], p["x"], p["z"], args.margin)
    areas = []
    for a in args.area:
        x1, z1, x2, z2 = [int(v) for v in a.split(",")]
        areas.append({"name": f"A{len(areas) + 1}", "x1": min(x1, x2), "z1": min(z1, z2), "x2": max(x1, x2), "z2": max(z1, z2),
                      "ymin": -58, "ymax": 32})
        add_chunk_box(x1, z1, x2, z2, args.margin)

    print(f"2. converting {len(wanted)} chunks ...", file=sys.stderr)
    by_region = {}
    for cx, cz in wanted:
        by_region.setdefault((cx // 32, cz // 32), []).append((cx, cz))
    containers, block_counts = [], {}
    for (rx, rz), chunks in sorted(by_region.items()):
        path = os.path.join(world, "region", f"r.{rx}.{rz}.mca")
        if not os.path.exists(path):
            continue
        reg = nbt.Region(path)
        for cx, cz in sorted(chunks):
            try:
                chunk = reg.chunk(cx, cz)
            except Exception as e:
                print(f"   chunk {cx},{cz} is damaged in the backup ({e}); left empty", file=sys.stderr)
                continue
            if not chunk:
                continue
            lines = runs_for_chunk(chunk)
            if lines:
                with open(os.path.join(out, "chunks", f"{cx}_{cz}.txt"), "w", encoding="utf-8", newline="\n") as f:
                    f.write("".join(lines))
            for be in chunk.get("block_entities", []):
                bid = be.get("id", "")
                block_counts[bid] = block_counts.get(bid, 0) + 1
                if bid == "enderstorage:ender_chest":
                    containers.append({"x": be["x"], "y": be["y"], "z": be["z"], "block": bid,
                                       "freq": frequency_key(be.get("Frequency"))})

    # which frequency is which: from the miners' and delivery turtles' packs
    ender = {}
    for spec in fleet:
        if spec.get("role") == "miner":
            inv = spec["turtle"]["inv"]
            if 15 in inv and "frequency" in inv[15]:
                ender.setdefault("fuel", inv[15]["frequency"])
            if 16 in inv and "frequency" in inv[16]:
                ender.setdefault("ore", inv[16]["frequency"])
        if spec.get("role") == "delivery":
            inv = spec["turtle"]["inv"]
            if 16 in inv and "frequency" in inv[16]:
                ender.setdefault("delivery", inv[16]["frequency"])

    print("3. copying computer disks ...", file=sys.stderr)
    for spec in fleet:
        src = os.path.join(disk_root, str(spec["id"]))
        dst = os.path.join(out, "disks", str(spec["id"]))
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst)

    storage = []
    if args.storage:
        with open(args.storage, "r", encoding="utf-8") as f:
            state = json.load(f)
        for it in state.get("storage", []):
            storage.append({"name": it["name"], "amount": it.get("amount", 0), "displayName": it.get("displayName"),
                            "craftable": bool(it.get("craftable"))})

    # EnderStorage chest contents
    contents = {}
    es = os.path.join(world, "EnderStorage")
    if os.path.isdir(es):
        for fn in os.listdir(es):
            if fn.endswith(".dat") and fn != "lock.dat":
                try:
                    data = nbt.read_nbt_file(os.path.join(es, fn))
                except Exception:
                    continue
                contents[fn] = data
    # chunks the world keeps loaded for ever: tickets from the chunk-loader blocks and from Advanced Peripherals
    # (data/chunks.dat, ForgeForced). A chunk is stored packed: z in the high 32 bits, x in the low 32.
    base_chunks = set()
    try:
        forced = nbt.read_nbt_file(os.path.join(world, "data", "chunks.dat"))["data"]
        for entry in forced.get("ForgeForced", []):
            for item in entry.get("ModForced", []):
                c = item["Chunk"]
                x, z = c & 0xFFFFFFFF, c >> 32
                if x >= 2 ** 31:
                    x -= 2 ** 32
                base_chunks.add((x, z))
    except Exception as e:
        print(f"   could not read the forced chunk list ({e}); using the depot rectangle only", file=sys.stderr)
    # the clock: a minute after the dispatch server last wrote its alive stamp ("<epoch ms> <version>")
    start_ms = None
    for spec in fleet:
        if spec.get("role") == "server":
            p = os.path.join(disk_root, str(spec["id"]), "alive.stamp")
            if os.path.exists(p):
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    try:
                        start_ms = int(f.read().split()[0]) + 60000
                    except (ValueError, IndexError):
                        pass
    meta = {
        "start_ms": start_ms,
        "base_loaded": [[100, -2850, 260, -2750]],  # the depot itself, as a safety net
        "base_loaded_chunks": [[x, z] for x, z in sorted(base_chunks)],
        "areas": areas, "ender": ender, "imported_from": os.path.basename(world),
        "containers": containers, "gps_hosts": [],
    }
    with open(os.path.join(out, "meta.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("return " + lua_value(meta))
    with open(os.path.join(out, "fleet.json"), "w", encoding="utf-8") as f:
        json.dump({"fleet": fleet, "skipped": skipped}, f, indent=1)
    with open(os.path.join(out, "storage.json"), "w", encoding="utf-8") as f:
        json.dump(storage, f)
    with open(os.path.join(out, "ender.json"), "w", encoding="utf-8") as f:
        json.dump({"frequencies": ender, "contents_files": sorted(contents.keys())}, f, indent=1)
    print(f"done: {len(wanted)} chunks, {len(fleet)} computers, {len(storage)} storage entries, {len(containers)} ender chests", file=sys.stderr)


if __name__ == "__main__":
    main()
