"""Derives what a turtle's pickaxe drops from each block, from the loot tables inside a modpack's jars.

Read-only: it opens jars with zipfile in read mode and writes ONE file, the derived drop table (no mod code, no
copied assets). Usage:

    python sandbox/tools/derive_drops.py <modpack-instance-dir> <vanilla-jar> <out.json> <block-source>...

<block-source> is a sandbox world's chunks folder (lines "r x z y1 y2 block") or a text file of block ids, one per line.
Only blocks found there are derived.

A turtle digs with a pickaxe: no silk touch, no fortune (enchantment level 0), no explosion. The table says, per block,
what can drop: {"item", "min", "max", "chance"} where count is uniform in min..max. Anything this tool could not
evaluate is listed in "unhandled" for that block instead of being guessed. Overrides are looked for in the instance's
kubejs/ and datapacks/ folders and in the jars' global loot modifiers; their presence is recorded in "overrides".
"""
import glob
import hashlib
import json
import os
import sys
import zipfile

LOOT = "data/%s/loot_tables/blocks/%s.json"


def jars_in(mods_dir):
    return sorted(glob.glob(os.path.join(mods_dir, "*.jar")), key=lambda p: os.path.basename(p).lower())


def block_ids(sources):
    ids = set()
    for src in sources:
        files = glob.glob(os.path.join(src, "*.txt")) if os.path.isdir(src) else [src]
        for f in files:
            with open(f, encoding="utf8") as h:
                for line in h:
                    parts = line.rstrip("\n").split("\t")
                    name = parts[5] if len(parts) >= 6 and parts[0] == "r" else parts[0].strip()
                    if ":" in name and not name.startswith("#"):
                        ids.add(name)
    return sorted(ids)


def whole(x):
    return int(x) if isinstance(x, float) and x == int(x) else x


def number(v, default=1):
    """A loot number provider at enchantment level 0: returns (min, max)."""
    if v is None:
        return default, default
    if isinstance(v, (int, float)):
        return v, v
    t = (v.get("type") or "minecraft:constant").split(":")[-1]
    if t == "constant":
        return v["value"], v["value"]
    if t == "uniform":
        lo, hi = number(v["min"]), number(v["max"])
        return lo[0], hi[1]
    if t == "binomial":
        n, _ = number(v["n"])
        return 0, n
    raise ValueError("number provider " + t)


def condition_true(c, unhandled):
    """Truth of a loot condition for a turtle's dig; None if it depends on something not modelled."""
    t = c.get("condition", "").split(":")[-1]
    if t == "survives_explosion":
        return True
    if t == "match_tool":
        # an enchantment requirement (silk touch, fortune >= 1) is not met by a plain pickaxe
        pred = c.get("predicate") or {}
        if pred.get("enchantments"):
            return False
        if pred.get("items") or pred.get("tag"):
            unhandled.append("match_tool on items " + json.dumps(pred)[:80])
            return None
        return True
    if t == "inverted":
        r = condition_true(c["term"], unhandled)
        return None if r is None else (not r)
    if t == "any_of":
        rs = [condition_true(x, unhandled) for x in c.get("terms", [])]
        return True if any(r is True for r in rs) else (None if None in rs else False)
    if t == "all_of":
        rs = [condition_true(x, unhandled) for x in c.get("terms", [])]
        return False if any(r is False for r in rs) else (None if None in rs else True)
    if t == "random_chance":
        return ("chance", c["chance"])
    if t == "table_bonus":
        ch = c.get("chances") or [1.0]
        return ("chance", ch[0])
    unhandled.append("condition " + c.get("condition", "?"))
    return None


def eval_conditions(conds, unhandled):
    """-> (possible, chance)"""
    chance = 1.0
    for c in conds or []:
        r = condition_true(c, unhandled)
        if r is False:
            return False, 0.0
        if r is None:
            unhandled.append("treated as true: " + c.get("condition", "?"))
        elif isinstance(r, tuple):
            chance *= r[1]
    return True, chance


def apply_functions(funcs, unhandled):
    lo, hi = 1, 1
    for f in funcs or []:
        ok, _ = eval_conditions(f.get("conditions"), unhandled)
        if not ok:
            continue
        t = f.get("function", "").split(":")[-1]
        if t == "set_count":
            a, b = number(f.get("count"))
            if f.get("add"):
                lo, hi = lo + a, hi + b
            else:
                lo, hi = a, b
        elif t == "apply_bonus":
            formula = f.get("formula", "").split(":")[-1]
            if formula in ("ore_drops", "uniform_bonus_count"):
                pass  # level 0: no bonus
            elif formula == "binomial_with_bonus_count":
                extra = (f.get("parameters") or {}).get("extra", 0)
                hi += extra   # 0..extra more with probability p each; the maximum is recorded
                unhandled.append("binomial bonus: count may be up to %d more" % extra)
            else:
                unhandled.append("apply_bonus " + formula)
        elif t == "limit_count":
            lim = f.get("limit") or {}
            if isinstance(lim, dict):
                if "max" in lim:
                    hi = min(hi, number(lim["max"])[1]); lo = min(lo, hi)
                if "min" in lim:
                    lo = max(lo, number(lim["min"])[0]); hi = max(hi, lo)
        elif t in ("explosion_decay", "copy_name", "copy_nbt", "copy_state", "set_nbt", "set_name", "set_lore",
                   "set_contents", "set_attributes", "set_potion", "set_enchantments"):
            pass
        else:
            unhandled.append("function " + f.get("function", "?"))
    return lo, hi


def entry_drops(e, unhandled):
    ok, chance = eval_conditions(e.get("conditions"), unhandled)
    if not ok:
        return []
    t = e.get("type", "").split(":")[-1]
    if t == "item":
        lo, hi = apply_functions(e.get("functions"), unhandled)
        return [{"item": e["name"], "min": whole(lo), "max": whole(hi), "chance": chance}]
    if t == "alternatives":
        for ch in e.get("children", []):
            d = entry_drops(ch, unhandled)
            if d:
                return [dict(x, chance=x["chance"] * chance) for x in d]
        return []
    if t in ("group", "sequence"):
        out = []
        for ch in e.get("children", []):
            out += [dict(x, chance=x["chance"] * chance) for x in entry_drops(ch, unhandled)]
        return out
    if t == "empty":
        return []
    unhandled.append("entry " + e.get("type", "?"))
    return []


def table_drops(table):
    unhandled = []
    drops = []
    for pool in table.get("pools", []):
        ok, pchance = eval_conditions(pool.get("conditions"), unhandled)
        if not ok:
            continue
        rolls = number(pool.get("rolls"))
        if rolls != (1, 1):
            unhandled.append("rolls %s" % (rolls,))
        for e in pool.get("entries", []):
            for d in entry_drops(e, unhandled):
                d = dict(d, chance=round(d["chance"] * pchance, 6))
                if pool.get("functions"):
                    lo, hi = apply_functions(pool["functions"], unhandled)
                    d["min"], d["max"] = whole(d["min"] * lo), whole(d["max"] * hi)
                drops.append(d)
    return drops, sorted(set(unhandled))


# What the overrides found in this instance do to a turtle's dig. Written by hand after reading each file; re-check when
# the mod set changes.
REVIEWED = [
    "kubejs/server_scripts/example.js is the stock example (console.info only); kubejs/data, datapacks/ and moonlight-global-datapacks/ are empty.",
    "Global loot modifiers in 9 jars: none changes the drop of a block broken by a plain turtle pickaxe. TConstruct's 'lustrous' and chrysophilite "
    "add ore entries only for a tool carrying that Tinkers modifier; Artifacts' pickaxe heater needs the artifact worn; the others touch chests, "
    "mobs, leaves, grass, fishing, flax or archaeology.",
    "Quark's jar also carries a loot table for glass and stained glass (clear shards behind a config flag); those blocks are marked unhandled.",
    "The instance is the CLIENT pack (packwiz); the server's mod set may differ.",
]


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        sys.exit(2)
    pack, vanilla, out = sys.argv[1], sys.argv[2], sys.argv[3]
    ids = block_ids(sys.argv[4:])
    jar_paths = [vanilla] + jars_in(os.path.join(pack, "mods"))
    tables = {}       # block id -> (jar basename, parsed table)
    conflicts = {}
    glm = []
    read_jars = []
    for jp in jar_paths:
        try:
            z = zipfile.ZipFile(jp, "r")
        except zipfile.BadZipFile:
            continue
        names = set(z.namelist())
        read_jars.append({"jar": os.path.basename(jp), "bytes": os.path.getsize(jp)})
        for b in ids:
            ns, path = b.split(":", 1)
            n = LOOT % (ns, path)
            if n in names:
                if b in tables:
                    conflicts.setdefault(b, [tables[b][0]]).append(os.path.basename(jp))
                tables[b] = (os.path.basename(jp), json.loads(z.read(n).decode("utf8")))
        for n in names:
            if n.endswith("loot_modifiers/global_loot_modifiers.json"):
                glm.append(os.path.basename(jp) + ":" + n)
    overrides = {"global_loot_modifiers": sorted(glm), "kubejs_files": [], "datapack_files": []}
    for sub, key in (("kubejs/server_scripts", "kubejs_files"), ("kubejs/data", "kubejs_files"),
                     ("datapacks", "datapack_files")):
        d = os.path.join(pack, sub)
        for root, _, files in os.walk(d):
            for f in files:
                overrides[key].append(os.path.relpath(os.path.join(root, f), pack).replace("\\", "/"))
    blocks = {}
    for b in ids:
        if b not in tables:
            blocks[b] = {"source": None, "note": "no block loot table found in the jars"}
            continue
        jar, table = tables[b]
        drops, unhandled = table_drops(table)
        blocks[b] = {"source": jar, "drops": drops}
        if unhandled:
            blocks[b]["unhandled"] = unhandled
        if b in conflicts:
            blocks[b]["also_in"] = conflicts[b][1:]
    result = {
        "about": "Derived by sandbox/tools/derive_drops.py from the loot tables of a CLIENT instance; no mod code is copied. "
                 "Drops are for a plain pickaxe (no silk touch, no fortune). Unverified until a local test server confirms them.",
        "instance": os.path.basename(os.path.normpath(pack)),
        "overrides_found": overrides,
        "overrides_reviewed": REVIEWED,
        "jars_read": read_jars,
        "blocks": blocks,
    }
    with open(out, "w", encoding="utf8", newline="\n") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    missing = [b for b in ids if blocks[b]["source"] is None]
    print("blocks: %d, with a loot table: %d, without: %d, jars read: %d" % (len(ids), len(ids) - len(missing), len(missing), len(read_jars)))
    print("global loot modifiers:", overrides["global_loot_modifiers"])
    print("kubejs/datapack files:", overrides["kubejs_files"], overrides["datapack_files"])


if __name__ == "__main__":
    main()
