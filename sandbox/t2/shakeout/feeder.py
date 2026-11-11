"""Shakeout job feeder and housekeeping (plan Task 6; spec section 2). T2 ONLY: orders go through the T2 bridge's POST /command.

    f = feeder.Feeder(ctx)            # min_jobs=10, max_idle_s=600, sites=3, destinations=4
    f.tick(now)                       # called every poll by scenarios/shakeout.py run_loop (now = wall-clock seconds)
    feeder.housekeep(ctx, now)        # ditto: the logged RS-headroom check

THE LOAD TARGET (not a pass check): at least min_jobs MINE/DELIVER jobs active at all times, and no online, unheld turtle sitting
IDLE for more than max_idle_s outside a fault. Turtles between jobs or recovering are fine; the feeder only counts what /state shows.
IDLE WATCH: a turtle seen IDLE for IDLE_ACT_FRACTION of max_idle_s (half: the dispatch itself takes time) is given work, SIZED TO
THE COUNT: one delivery per idle delivery turtle, and mining orders (zones of up to MINERS_PER_ZONE miners each) until every idle
miner has capacity. Only turtles actually given work have their idle clock reset; when work cannot be placed (no stock, no fresh
ground) the idleness stays on the clock, and is said, never hidden.

HOW A MINING ORDER IS BUILT. ORDER_MINE takes sector CENTRES, not a footprint (memory "ORDER_MINE takes centres"): the server
snaps the corners to its 32-block grid (floor/ceil) and pads the result by 16 (central_server.lua buildSectorGrid), so a zone is
always [first centre - 16, last centre + 16]. Every zone below is given as the centres themselves, already multiples of 32, so what
is ordered is what is covered and nothing grows (a footprint order grew 3 sectors into 15). Zone identity on the server is that
exact padded box (computeZoneKey), and an order overlapping worked ground re-mines it, so the zones are laid out disjoint AFTER the
padding. ZONES is a grid of 6x6-sector zones (36 sectors, twelve miners at the server's one per three sectors): pitch 224 blocks,
so the padded boxes (192 wide) are 32 clear of each other. They start at x 512, z -2400: west of nothing worked, clear of the base
(world.BASE_AREAS, x <= 331) and south of every sector the live server mined (WORKED_GROUND: all 158 sectors of
docs/measurements/2026-09-22-zone-ore-map-dump.txt, x 928-2080, z -3808..-2496, plus the T2 scenarios' (1920..2016, -2624) and
(2944, -2624)). The list is ordered nearest-the-base first and the feeder walks it once: a zone, once ordered, is spent, and when
the list runs out the feeder says so (once) and stops ordering mining rather than reuse ground.
SIZE: a 24-hour run needs  hours x miners / (sector_time / speed)  sectors (an ore sector is ~9,400 s per miner at 1x): at 4x and
128 miners that is 4,706; ZONES holds 143 x 36 = 5,148 (the test works the sum out).

DELIVERIES carry ordinary stock the warehouse holds (cobblestone first, else the biggest non-ore stack of at least 64 in /state
storage), 16 at a time, rotating over DESTINATIONS (six spots south of the building, staggered in z: a row of destinations on one z
is what piled 19 turtles up on 2026-11-03). Feeder() asks the game once whether each spot is still air (the free_spot probe) and
drops one that is not.

HOUSEKEEPING (spec 2: storage stays in its normal range, never full by accident). Delivery stock is Refined Storage (cobblestone
2.55M): it needs no top-up, and ore and fuel chests already drain and stock themselves through RS importers and exporters, so there
is nothing to refill. The real risk is RS HEADROOM: free space somewhere 7M-53M against 5-16M of ore inflow at full load. Each
HOUSEKEEP_EVERY_S housekeep() reads used (the sum of /state "storage" amounts: rsBridge.listItems, verified in central_server.lua)
against a capacity measured once from the world's RS disk data (rs_capacity_of_world; SHAKEOUT_RS_CAPACITY overrides) and logs
`HOUSEKEEPING storage-headroom ok|low|unknown ...` to <run>/shakeout/housekeeping.log. `low` (free under LOW_FREE_FRACTION of
capacity, or under one period of inflow) is the fixed tag the report reads as a named finding, and is followed by a drain: an
ORDER_DELIVERY of the biggest ore stack out of RS to the base's trash can (DRAIN_DESTINATION). VERIFY THAT ON T2 FIRST: it uses
only existing orders, but whether the hand-off lands in the can is unproven. It goes through ctx.dispatch and the raw control
(ctx._raw), never ctx.control, so it is never an INTERVENTION. Storage filling up is otherwise only the scheduled rs_offline fault.
"""
import json
import math
import os
import time


MIN = 60
ACTIVE = ("PENDING", "ASSIGNED", "IN_PROGRESS")
PAD = 16                    # the server's scan radius pad
STEP = 32                   # the server's sector grid

# Every sector the live server mined (docs/measurements/2026-09-22-zone-ore-map-dump.txt: 158 sector centres, [done] and not), kept
# here so a test can compare them with the dump, and the T2 scenarios' ground. Padded by the scan radius they are WORKED_GROUND.
DUMP_SECTORS = [
    (928, -3264), (928, -3232), (928, -3200), (928, -3168), (928, -3136), (960, -3264), (960, -3232), (960, -3200),
    (960, -3168), (960, -3136), (992, -3264), (992, -3232), (992, -3200), (992, -3168), (992, -3136), (1024, -3232),
    (1024, -3200), (1024, -3168), (1024, -3136), (1024, -2528), (1024, -2496), (1056, -3264), (1056, -3232), (1056, -3200),
    (1056, -3168), (1056, -3136), (1056, -2816), (1056, -2784), (1056, -2752), (1056, -2592), (1056, -2528), (1088, -3264),
    (1088, -3232), (1088, -3200), (1088, -3168), (1088, -2976), (1088, -2912), (1088, -2816), (1088, -2784), (1088, -2752),
    (1088, -2592), (1088, -2560), (1088, -2528), (1088, -2496), (1120, -3264), (1120, -3232), (1120, -3200), (1120, -3168),
    (1120, -3136), (1120, -2976), (1120, -2944), (1120, -2912), (1120, -2816), (1120, -2784), (1120, -2752), (1120, -2560),
    (1152, -2976), (1152, -2944), (1152, -2912), (1152, -2816), (1152, -2784), (1152, -2752), (1152, -2592), (1152, -2560),
    (1184, -2816), (1184, -2784), (1184, -2752), (1248, -3360), (1248, -3328), (1280, -3360), (1280, -3328), (1280, -3168),
    (1280, -3136), (1312, -3712), (1312, -3680), (1312, -3616), (1312, -3360), (1312, -3328), (1312, -3168), (1312, -3136),
    (1344, -3680), (1344, -3648), (1344, -3168), (1344, -3136), (1376, -3680), (1376, -3648), (1376, -3616), (1376, -3424),
    (1376, -3392), (1376, -3168), (1376, -3136), (1408, -3808), (1408, -3776), (1408, -3648), (1408, -3424), (1408, -3392),
    (1440, -3808), (1440, -3776), (1440, -3680), (1440, -3616), (1568, -3456), (1568, -3424), (1600, -3456), (1600, -3424),
    (1600, -3296), (1600, -3264), (1600, -3232), (1632, -3296), (1632, -3264), (1632, -3232), (1664, -3296), (1664, -3264),
    (1664, -3232), (1696, -3296), (1696, -3264), (1696, -3232), (1760, -3040), (1760, -3008), (1792, -3040), (1792, -3008),
    (1856, -3040), (1856, -3008), (1856, -2944), (1856, -2912), (1888, -3040), (1888, -3008), (1888, -2944), (1888, -2912),
    (1952, -3200), (1952, -3168), (1952, -3104), (1952, -3072), (1952, -3008), (1952, -2944), (1952, -2912), (1952, -2848),
    (1952, -2816), (1984, -3200), (1984, -3168), (1984, -3104), (1984, -3072), (1984, -3008), (1984, -2944), (1984, -2912),
    (1984, -2848), (1984, -2816), (2048, -3104), (2048, -3072), (2048, -3008), (2048, -2976), (2048, -2912), (2048, -2880),
    (2080, -3104), (2080, -3072), (2080, -3008), (2080, -2976), (2080, -2912), (2080, -2880),
]
DUMP_ZONES = [(1744, -3056, 1808, -2992), (1040, -2832, 1200, -2736), (1936, -3216, 2000, -3152), (1936, -2960, 2000, -2896), (1232, -3376, 1328, -3312), (1424, -3152, 1520, -3056), (1264, -3504, 1328, -3440), (1040, -2992, 1168, -2896), (1840, -3152, 1904, -3088), (1296, -3728, 1456, -3600), (2032, -3120, 2096, -3056), (1264, -3184, 1392, -3120), (1936, -3120, 2000, -3056), (1936, -2864, 2000, -2800), (1584, -3312, 1712, -3216), (912, -3280, 1136, -3120), (1840, -3056, 1904, -2992), (1392, -3824, 1456, -3760), (1552, -3472, 1616, -3408), (2032, -3024, 2096, -2960), (1008, -2608, 1168, -2480), (1360, -3440, 1424, -3376), (1936, -3024, 2000, -2992), (1840, -2960, 1904, -2896), (2032, -2928, 2096, -2864), (1520, -2992, 1584, -2960)]      # the 26 zone boxes of the same dump (already padded)
SCENARIO_SECTORS = [(1920, -2624), (1952, -2624), (1984, -2624), (2016, -2624), (2944, -2624)]
WORKED_GROUND = [(x - PAD, z - PAD, x + PAD, z + PAD) for x, z in DUMP_SECTORS + SCENARIO_SECTORS] + list(DUMP_ZONES)

ZONE_SECTORS = 6                 # a zone is 6x6 sectors
MINERS_PER_ZONE = ZONE_SECTORS * ZONE_SECTORS // 3      # the server's SECTORS_PER_MINER = 3
ZONE_PITCH = 224                 # 5 x 32 between the first and last centre + 64: the padded boxes end up 32 clear
GRID_X0, GRID_Z0, GRID_COLS, GRID_ROWS = 512, -2400, 13, 11
BASE_CENTRE = (200, -2800)
SECTOR_SECONDS_1X = 9400         # one ore sector, one miner, at 1x (measured)


def _zone(zid, kind, x1, z1, x2, z2):
    return {"id": zid, "kind": kind, "x1": x1, "z1": z1, "x2": x2, "z2": z2}


def _build_zones():
    span = (ZONE_SECTORS - 1) * STEP
    zones = []
    for r in range(GRID_ROWS):
        for c in range(GRID_COLS):
            x, z = GRID_X0 + ZONE_PITCH * c, GRID_Z0 + ZONE_PITCH * r
            zones.append(_zone("zone_%d_%d" % (r, c), "long", x, z, x + span, z + span))
    zones.sort(key=lambda z: (math.hypot(z["x1"] + 80 - BASE_CENTRE[0], z["z1"] + 80 - BASE_CENTRE[1]), z["id"]))
    return zones


ZONES = _build_zones()

# Where deliveries go: free ground south of the building, staggered in z (a row on one z piled 19 turtles up on 2026-11-03).
DESTINATIONS = [(160, 67, -2752), (172, 67, -2755), (184, 67, -2758), (196, 67, -2761), (208, 67, -2764), (220, 67, -2767)]
ITEM_COUNT = 16
GRACE_S = 10 * MIN          # a freshly ordered site counts as open this long, while its jobs are still pending
IDLE_ACT_FRACTION = 0.5     # a turtle is given work after this share of max_idle_s: the dispatch itself takes time
MAX_ORDERS_PER_TICK = 6     # the site / top-up orders; idle-watch orders have their own, larger, cap
MAX_IDLE_ORDERS_PER_TICK = 30
NOTE_EVERY_S = 30 * MIN     # how often one kind of complaint may be repeated


def zone_key(z):
    """The key the server gives the zone (computeZoneKey over buildSectorGrid's padded bounds), as /state jobs carry it."""
    x1, x2 = sorted((z["x1"], z["x2"]))
    z1, z2 = sorted((z["z1"], z["z2"]))
    x1, x2 = math.floor(x1 / STEP) * STEP, math.ceil(x2 / STEP) * STEP
    z1, z2 = math.floor(z1 / STEP) * STEP, math.ceil(z2 / STEP) * STEP
    return "%d,%d,%d,%d" % (x1 - PAD, z1 - PAD, x2 + PAD, z2 + PAD)


def sectors_needed(hours=24.0, miners=128, speed=4.0, sector_seconds_1x=SECTOR_SECONDS_1X):
    """How many sectors a run consumes if every miner always works: hours x miners / (sector time at that speed)."""
    return math.ceil(hours * 3600.0 * miners / (sector_seconds_1x / speed))


def _as_list(v):
    if isinstance(v, dict):
        return [dict(e, id=k) if isinstance(e, dict) and "id" not in e else e for k, e in v.items()]
    return list(v or [])


class Feeder:
    def __init__(self, ctx, min_jobs=10, max_idle_s=600, sites=3, destinations=4):
        self.ctx = ctx
        self.min_jobs, self.max_idle_s, self.sites = min_jobs, max_idle_s, sites
        self.next_zone = 0
        self.zones = list(ZONES)
        self.open_sites = {}            # zone id -> when it was ordered
        self.seen_keys = set()          # zone keys ever seen on an active job
        self.idle_since = {}            # node id -> when first seen idle
        self.next_dest = 0
        self.exhausted = False
        self.noted = {}
        self.dests = self._probe(list(DESTINATIONS), destinations)

    def _note_every(self, now, key, text):
        if now - self.noted.get(key, -1e12) >= NOTE_EVERY_S:
            self.noted[key] = now
            self.ctx.note(text)

    def _probe(self, spots, want):
        """The free_spot-style air probe, once: a destination whose block or the one above it is explicitly not air is dropped."""
        raw = getattr(self.ctx, "_raw", None)
        keep = []
        for x, y, z in spots:
            ok = True
            for dy in (0, 1):
                try:
                    reply = raw.command("execute if block %d %d %d air" % (x, y + dy, z)) if raw else ""
                except Exception:  # noqa: BLE001 - an unanswered probe is not a reason to drop a spot
                    reply = ""
                if "Test failed" in (reply or ""):
                    ok = False
            if ok:
                keep.append((x, y, z))
            else:
                self.ctx.note("feeder: destination %d,%d,%d is not air: dropped" % (x, y, z))
        if len(keep) < want:
            self.ctx.note("feeder: only %d usable delivery destinations (%d wanted)" % (len(keep), want))
        return keep

    # -- reading ----------------------------------------------------------------------------------------------------
    def _look(self):
        st = self.ctx.state() or {}
        jobs = [j for j in _as_list(st.get("jobs")) if isinstance(j, dict) and j.get("status") in ACTIVE
                and j.get("type") in ("MINE", "DELIVER")]
        turtles = st.get("turtles") or {}
        if isinstance(turtles, list):
            turtles = {t.get("id"): t for t in turtles}
        return st, jobs, turtles

    # -- ordering ---------------------------------------------------------------------------------------------------
    def _order_mine(self, now, miners):
        """One order for the next fresh zone, asking for up to `miners` (at most what the zone holds). Returns the miners covered."""
        if self.next_zone >= len(self.zones):
            if not self.exhausted:
                self.exhausted = True
                self.ctx.note("feeder: the mining zones are exhausted; no ground is reused, so no more are ordered")
            return 0
        z = self.zones[self.next_zone]
        self.next_zone += 1
        k = max(1, min(int(miners), MINERS_PER_ZONE))
        self.ctx.dispatch("ORDER_MINE", {"x1": z["x1"], "z1": z["z1"], "x2": z["x2"], "z2": z["z2"], "minerCount": k})
        self.open_sites[z["id"]] = now
        return k

    def _stock_item(self, st):
        best = None
        for e in st.get("storage") or []:
            if not isinstance(e, dict):
                continue
            n, a = e.get("name"), e.get("amount") or e.get("count") or 0
            if not isinstance(n, str) or a < 4 * ITEM_COUNT or "ore" in n or n.startswith("minecraft:raw_"):
                continue
            if n == "minecraft:cobblestone":
                return n
            if best is None or a > best[1]:
                best = (n, a)
        return best[0] if best else None

    def _order_delivery(self, st, now):
        item = self._stock_item(st)
        if item is None:
            self._note_every(now, "nostock", "feeder: no ordinary stock of at least %d in storage to deliver" % (4 * ITEM_COUNT))
            return False
        if not self.dests:
            self._note_every(now, "nodest", "feeder: no usable delivery destination")
            return False
        x, y, z = self.dests[self.next_dest % len(self.dests)]
        self.next_dest += 1
        self.ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": item, "count": ITEM_COUNT}],
                                             "destination": {"x": x, "y": y, "z": z}})
        return True

    # -- the tick ---------------------------------------------------------------------------------------------------
    def tick(self, now):
        st, jobs, turtles = self._look()
        keys_open = {j.get("zoneKey") for j in jobs if j.get("type") == "MINE" and j.get("zoneKey")}
        self.seen_keys |= keys_open
        by_id = {z["id"]: z for z in self.zones}
        for zid in list(self.open_sites):
            key = zone_key(by_id[zid])
            if key not in keys_open and now - self.open_sites[zid] > GRACE_S:
                if key not in self.seen_keys:
                    self.ctx.note("feeder: the order for %s never showed up as a job (zoneKey %s)" % (zid, key))
                    self.seen_keys.add(key)
                del self.open_sites[zid]
        placed = 0

        # 1. keep `sites` sites open
        while len(self.open_sites) < self.sites and placed < MAX_ORDERS_PER_TICK:
            if not self._order_mine(now, MINERS_PER_ZONE):
                break
            placed += 1
            jobs.append({"type": "MINE"})

        # 2. keep the job count up with mining (the open sites are shared, a new zone adds jobs)
        shortfall = self.min_jobs - len(jobs)
        while shortfall > 0 and placed < MAX_ORDERS_PER_TICK:
            got = self._order_mine(now, shortfall)
            if not got:
                break
            shortfall -= got
            placed += 1

        # 3. idle watch: size the work to the idle count; only the turtles actually given work restart their clock
        act_after = self.max_idle_s * IDLE_ACT_FRACTION
        idle = {"MINER": [], "DELIVERY": []}
        seen = set()
        for tid, t in turtles.items():
            if not isinstance(t, dict) or t.get("role") not in idle:
                continue
            seen.add(tid)
            if t.get("status") != "IDLE" or not t.get("online", True) or t.get("held") or t.get("needsHands"):
                self.idle_since.pop(tid, None)
                continue
            since = self.idle_since.setdefault(tid, now)
            if now - since > act_after:
                idle[t["role"]].append((since, tid))
        for tid in [k for k in self.idle_since if k not in seen]:
            del self.idle_since[tid]
        orders = 0
        for _, tid in sorted(idle["DELIVERY"]):
            if orders >= MAX_IDLE_ORDERS_PER_TICK or not self._order_delivery(st, now):
                break
            orders += 1
            self.idle_since[tid] = now
        want = [tid for _, tid in sorted(idle["MINER"])]
        while want and orders < MAX_IDLE_ORDERS_PER_TICK:
            got = self._order_mine(now, len(want))
            if not got:
                break
            orders += 1
            for tid in want[:got]:
                self.idle_since[tid] = now
            want = want[got:]
        if want:
            self._note_every(now, "unserved", "feeder: %d idle miners could not be given work (ground exhausted or order cap)" % len(want))


# ---------------------------------------------------------------------------------------------------------------------------
# Housekeeping: the RS headroom check
# ---------------------------------------------------------------------------------------------------------------------------

HOUSEKEEP_EVERY_S = 30 * MIN
LOW_FREE_FRACTION = 0.20            # free under this share of capacity is "low"
INFLOW_PER_DAY = 16000000           # items a full-load day brings in (5-16M measured); low also when free < two periods of it
DRAIN_COUNT = 2048                  # items of ore moved out per low reading
DRAIN_DESTINATION = (174, 67, -2829)    # the item trash can by the RS controller (world copy)
RS_DISKS_FILE = os.path.join("data", "refinedstorage_disks.dat")


def _env_int(name):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return None


RS_CAPACITY = _env_int("SHAKEOUT_RS_CAPACITY")      # items the RS disks hold; measured from the world at the first check when unset


def capacity_of_disks(disks):
    """Total item capacity of a decoded refinedstorage disks list ([{Type, Data: {Capacity, Items}}]): the sum over item disks;
    math.inf when any item disk is unlimited (Capacity <= 0); None when there is no item disk."""
    total, n = 0, 0
    for d in disks or []:
        if not isinstance(d, dict) or d.get("Type") != "refinedstorage:item":
            continue
        n += 1
        cap = (d.get("Data") or {}).get("Capacity")
        if not isinstance(cap, (int, float)) or cap <= 0:
            return math.inf
        total += cap
    return total if n else None


def rs_capacity_of_world(world):
    """Reads <world>/data/refinedstorage_disks.dat (host file read, the game untouched); None when it cannot be read."""
    try:
        import importlib.util
        here = os.path.dirname(os.path.abspath(__file__))
        spec = importlib.util.spec_from_file_location("sandbox_nbt", os.path.join(here, "..", "..", "tools", "nbt.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        doc = mod.read_nbt_file(os.path.join(world, RS_DISKS_FILE))
        return capacity_of_disks(doc["data"]["Disks"])
    except Exception:  # noqa: BLE001 - no capacity is reported as unknown, not guessed
        return None


def _hk_log(ctx, what):
    d = os.path.join(ctx.run, "shakeout")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "housekeeping.log"), "a", encoding="utf8") as f:
        f.write("%s HOUSEKEEPING %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), what))


def _drain_ore(ctx, storage):
    """Moves ore out of RS with an ordinary delivery order to the trash can. VERIFY ON T2 FIRST: unproven end to end."""
    best = None
    for e in storage or []:
        n, a = (e or {}).get("name"), (e or {}).get("amount") or 0
        if isinstance(n, str) and ("ore" in n or n.startswith("minecraft:raw_")) and a > 0 and (best is None or a > best[1]):
            best = (n, a)
    if best is None:
        return "drain_ore: no ore in storage to move"
    x, y, z = DRAIN_DESTINATION
    count = min(best[1], DRAIN_COUNT)
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": best[0], "count": count}], "destination": {"x": x, "y": y, "z": z}})
    return "drain_ore ordered %d x %s to %d,%d,%d (verify on T2 first)" % (count, best[0], x, y, z)


def housekeep(ctx, now):
    """Every HOUSEKEEP_EVERY_S: logs the RS headroom; when it is low, logs `storage-headroom-low` and drains ore. Returns the lines."""
    global RS_CAPACITY
    st = getattr(ctx, "shakeout_housekeeping", None)
    if st is None:
        ctx.shakeout_housekeeping = {"last": now}
        return []
    if now - st["last"] < HOUSEKEEP_EVERY_S:
        return []
    st["last"] = now
    out = []
    try:
        storage = (ctx.state() or {}).get("storage") or []
        used = sum((e.get("amount") or e.get("count") or 0) for e in storage if isinstance(e, dict))
        if RS_CAPACITY is None:
            RS_CAPACITY = rs_capacity_of_world(getattr(getattr(ctx, "_raw", None), "world", None) or "")
        cap = RS_CAPACITY
        if cap is None:
            out.append("storage-headroom-unknown: used %d items, no capacity measured (set SHAKEOUT_RS_CAPACITY)" % used)
        else:
            free = cap - used
            low = cap != math.inf and (free < LOW_FREE_FRACTION * cap or free < 2 * INFLOW_PER_DAY * HOUSEKEEP_EVERY_S / 86400.0)
            pct = "unlimited" if cap == math.inf else "%.1f%%" % (100.0 * free / cap)
            out.append("storage-headroom-%s used=%d capacity=%s free=%s" % ("low" if low else "ok", used,
                                                                          "unlimited" if cap == math.inf else int(cap), pct))
            if low:
                out.append(_drain_ore(ctx, storage))
    except Exception as ex:  # noqa: BLE001 - a failed check is logged, never the end of a 24-hour run
        out.append("storage-headroom-unknown: check failed: %s: %s" % (type(ex).__name__, ex))
    for what in out:
        _hk_log(ctx, what)
    return out
