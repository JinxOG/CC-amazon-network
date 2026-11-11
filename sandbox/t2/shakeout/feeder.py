"""Shakeout job feeder and housekeeping (plan Task 6; spec section 2). T2 ONLY: orders go through the T2 bridge's POST /command.

    f = feeder.Feeder(ctx)            # min_jobs=10, max_idle_s=600, sites=3, destinations=4
    f.tick(now)                       # called every poll by scenarios/shakeout.py run_loop (now = wall-clock seconds)
    feeder.housekeep(ctx, now)        # ditto: drains ore and tops up delivery stock on a fixed timetable

THE LOAD TARGET (not a pass check): at least min_jobs MINE/DELIVER jobs active at all times, and no online, unheld turtle sitting
IDLE for more than max_idle_s outside a fault. Turtles between jobs or recovering are fine; the feeder only counts what /state shows.

HOW A MINING ORDER IS BUILT. ORDER_MINE takes sector CENTRES, not a footprint (memory "ORDER_MINE takes centres"): the server
snaps the corners to its 32-block grid (floor/ceil) and pads the result by 16 (central_server.lua buildSectorGrid), so a zone is
always [first centre - 16, last centre + 16]. Every zone below is given as the centres themselves, already multiples of 32, so what
is ordered is what is covered and nothing grows (a footprint order grew 3 sectors into 15). Zone identity on the server is that
exact padded box (computeZoneKey), and an order overlapping worked ground re-mines it, so the zones are laid out disjoint AFTER the
padding: every neighbour is at least 96 blocks clear, and none touches the base (world.BASE_AREAS) or the ground earlier scenarios
worked (WORKED_GROUND). The feeder walks the list in order and never goes back: a zone, once ordered, is spent, and when the
list runs out the feeder says so (once) and stops ordering mining rather than reuse ground.
  "long" zones are 3x3 sectors (9 sectors, three miners at the server's one per three sectors): a site stays open a good while.
  The feeder keeps `sites` of them open (a site is open while an active job carries its zoneKey, or for a grace after ordering,
  while the jobs are pending); when one closes the next long zone opens. "short" zones are one sector and feed idle miners.

DELIVERIES carry ordinary stock the warehouse holds (cobblestone first, else the biggest non-ore stack of at least 64 in /state
storage), 16 at a time, rotating over DESTINATIONS (more than 4; spots on the free ground south of the building, y 67).

HOUSEKEEPING keeps storage in its normal range on a fixed timetable (DRAIN_EVERY_S, TOPUP_EVERY_S after the first call) and logs
each action as `HOUSEKEEPING <what>` in <run>/shakeout/housekeeping.log. It goes through the RAW control (ctx._raw), never
ctx.control, so it is never an INTERVENTION. What it does needs the world's storage blocks: ORE_DRAIN_POS (a chest the ore is
exported into: emptied) and STOCK_POS (a chest the stock is imported from: refilled), set here or through the environment
(SHAKEOUT_ORE_DRAIN_POS / SHAKEOUT_STOCK_POS = "x,y,z"). Not configured, an action is logged as skipped, never silently dropped.
Storage filling up is NOT housekeeping's to do or to allow by accident: it happens only as the scheduled rs_offline / disk faults.
"""
import json
import math
import os
import time


MIN = 60
ACTIVE = ("PENDING", "ASSIGNED", "IN_PROGRESS")
PAD = 16                    # the server's scan radius pad
STEP = 32                   # the server's sector grid

# Ground that earlier T2 scenarios worked (bounds after padding: sectors (1920..2016,-2624) and the proof scenarios' (2944,-2624)).
WORKED_GROUND = [(1904, -2640, 2032, -2608), (2928, -2640, 2960, -2608)]


def _zone(zid, kind, x1, z1, x2, z2):
    return {"id": zid, "kind": kind, "x1": x1, "z1": z1, "x2": x2, "z2": z2}


def _build_zones():
    zones = []
    for i in range(6):                                   # long sites: 3x3 sectors, bounds 160 wide, 192 apart
        x = 512 + 192 * i
        zones.append(_zone("long%d" % i, "long", x, -2624, x + 2 * STEP, -2624 + 2 * STEP))
    for r, z in enumerate((-2400, -2272, -2144, -2016)):  # short sites: one sector, 128 apart (96 clear after the pad)
        for c in range(8):
            x = 512 + 128 * c
            zones.append(_zone("short%d_%d" % (r, c), "short", x, z, x, z))
    return zones


ZONES = _build_zones()

# Where deliveries go: free ground south of the building (outside the dock rows), spaced so they never share a spot.
DESTINATIONS = [(x, 67, -2760) for x in (160, 172, 184, 196, 208, 220)]
ITEM_COUNT = 16
GRACE_S = 10 * MIN          # a freshly ordered long site counts as open this long, while its jobs are still pending
ORDER_GAP_S = 20            # never order more often than this per kind
MAX_ORDERS_PER_TICK = 6


def zone_key(z):
    """The key the server gives the zone (computeZoneKey over buildSectorGrid's padded bounds), as /state jobs carry it."""
    x1, x2 = sorted((z["x1"], z["x2"]))
    z1, z2 = sorted((z["z1"], z["z2"]))
    x1, x2 = math.floor(x1 / STEP) * STEP, math.ceil(x2 / STEP) * STEP
    z1, z2 = math.floor(z1 / STEP) * STEP, math.ceil(z2 / STEP) * STEP
    return "%d,%d,%d,%d" % (x1 - PAD, z1 - PAD, x2 + PAD, z2 + PAD)


def _as_list(v):
    if isinstance(v, dict):
        return [dict(e, id=k) if isinstance(e, dict) and "id" not in e else e for k, e in v.items()]
    return list(v or [])


class Feeder:
    def __init__(self, ctx, min_jobs=10, max_idle_s=600, sites=3, destinations=4):
        self.ctx = ctx
        self.min_jobs, self.max_idle_s, self.sites = min_jobs, max_idle_s, sites
        self.n_dest = max(destinations, 1)
        self.next_zone = {"long": 0, "short": 0}
        self.open_sites = {}            # zone id -> when it was ordered
        self.idle_since = {}            # node id -> when first seen idle
        self.next_dest = 0
        self.exhausted = set()
        self.last_order = {}
        self.pools = {k: [z for z in ZONES if z["kind"] == k] for k in ("long", "short")}

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
    def _zone_for(self, kind):
        pool = self.pools[kind]
        i = self.next_zone[kind]
        if i >= len(pool):
            if kind not in self.exhausted:
                self.exhausted.add(kind)
                self.ctx.note("feeder: the %s mining zones are exhausted; no ground is reused, so no more are ordered" % kind)
            return None
        self.next_zone[kind] = i + 1
        return pool[i]

    def _order_mine(self, kind, now, miners):
        z = self._zone_for(kind)
        if z is None:
            return None
        sectors = (abs(z["x2"] - z["x1"]) // STEP + 1) * (abs(z["z2"] - z["z1"]) // STEP + 1)
        self.ctx.dispatch("ORDER_MINE", {"x1": z["x1"], "z1": z["z1"], "x2": z["x2"], "z2": z["z2"],
                                         "minerCount": max(1, min(miners, math.ceil(sectors / 3.0)))})
        self.last_order[kind] = now
        return z

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
            self.ctx.note("feeder: no ordinary stock of at least %d in storage to deliver" % (4 * ITEM_COUNT))
            return False
        pool = DESTINATIONS
        x, y, z = pool[self.next_dest % max(len(pool), self.n_dest)]
        self.next_dest += 1
        self.ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": item, "count": ITEM_COUNT}],
                                             "destination": {"x": x, "y": y, "z": z}})
        self.last_order["deliver"] = now
        return True

    # -- the tick ---------------------------------------------------------------------------------------------------
    def tick(self, now):
        st, jobs, turtles = self._look()
        placed = 0
        keys_open = {j.get("zoneKey") for j in jobs if j.get("type") == "MINE" and j.get("zoneKey")}
        fleet_miners = sum(1 for t in turtles.values() if isinstance(t, dict) and t.get("role") == "MINER") or 1

        # 1. long sites: keep `sites` open; one that has no active job (and is past its grace) is finished, the next opens
        z_by_id = {z["id"]: z for z in self.pools["long"]}
        for zid in list(self.open_sites):
            if zone_key(z_by_id[zid]) not in keys_open and now - self.open_sites[zid] > GRACE_S:
                del self.open_sites[zid]
        while len(self.open_sites) < self.sites and placed < MAX_ORDERS_PER_TICK:
            z = self._order_mine("long", now, fleet_miners)
            if z is None:
                break
            self.open_sites[z["id"]] = now
            placed += 1
            jobs.append({"type": "MINE", "zoneKey": zone_key(z)})

        # 2. keep the job count up: deliveries first (the warehouse's real work), then short mining zones
        shortfall = self.min_jobs - len(jobs)
        while shortfall > 0 and placed < MAX_ORDERS_PER_TICK:
            made = False
            if self.last_order.get("deliver", -1e9) + ORDER_GAP_S <= now and self._order_delivery(st, now):
                shortfall -= 1
                placed += 1
                made = True
            if shortfall > 0 and placed < MAX_ORDERS_PER_TICK and self._order_mine("short", now, 1):
                shortfall -= 1
                placed += 1
                made = True
            if not made:
                break

        # 3. idle watch: a turtle online, unheld, IDLE for longer than max_idle_s is given work of its kind
        want = {"MINER": 0, "DELIVERY": 0}
        seen = set()
        for tid, t in turtles.items():
            if not isinstance(t, dict) or t.get("role") not in want:
                continue
            seen.add(tid)
            if t.get("status") != "IDLE" or not t.get("online", True) or t.get("held") or t.get("needsHands"):
                self.idle_since.pop(tid, None)
                continue
            since = self.idle_since.setdefault(tid, now)
            if now - since > self.max_idle_s:
                want[t["role"]] += 1
                self.idle_since[tid] = now           # it is being given work: count its idleness afresh
        for tid in [k for k in self.idle_since if k not in seen]:
            del self.idle_since[tid]
        if want["DELIVERY"]:
            for _ in range(min(want["DELIVERY"], 2)):
                self._order_delivery(st, now)
        if want["MINER"]:
            self._order_mine("short", now, min(want["MINER"], 3))


# ---------------------------------------------------------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------------------------------------------------------

DRAIN_EVERY_S = 60 * MIN
TOPUP_EVERY_S = 30 * MIN
STOCK_ITEM = "minecraft:cobblestone"
STOCK_COUNT = 64


def _pos_from_env(name):
    v = os.environ.get(name)
    try:
        x, y, z = (int(p) for p in v.split(","))
        return (x, y, z)
    except (AttributeError, ValueError):
        return None


ORE_DRAIN_POS = _pos_from_env("SHAKEOUT_ORE_DRAIN_POS")
STOCK_POS = _pos_from_env("SHAKEOUT_STOCK_POS")


def _hk_log(ctx, what):
    d = os.path.join(ctx.run, "shakeout")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "housekeeping.log"), "a", encoding="utf8") as f:
        f.write("%s HOUSEKEEPING %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), what))


def _drain_ore(ctx):
    if ORE_DRAIN_POS is None:
        return "drain_ore skipped: no ore drain chest configured (SHAKEOUT_ORE_DRAIN_POS)", False
    x, y, z = ORE_DRAIN_POS
    out = ctx._raw.command("data modify block %d %d %d Items set value []" % (x, y, z))
    return "drain_ore chest %d,%d,%d: %s" % (x, y, z, (out or "").strip()[:80]), True


def _topup_stock(ctx):
    if STOCK_POS is None:
        return "topup_stock skipped: no stock chest configured (SHAKEOUT_STOCK_POS)", False
    x, y, z = STOCK_POS
    out = ctx._raw.command("item replace block %d %d %d container.0 with %s %d" % (x, y, z, STOCK_ITEM, STOCK_COUNT))
    return "topup_stock chest %d,%d,%d: %d x %s: %s" % (x, y, z, STOCK_COUNT, STOCK_ITEM, (out or "").strip()[:80]), True


def housekeep(ctx, now):
    """Runs the timetable: the first call fixes the start; each action is due its period after the last (or after the start)."""
    st = getattr(ctx, "shakeout_housekeeping", None)
    if st is None:
        st = ctx.shakeout_housekeeping = {"drain_ore": now, "topup_stock": now}
        return []
    done = []
    for name, period, fn in (("drain_ore", DRAIN_EVERY_S, _drain_ore), ("topup_stock", TOPUP_EVERY_S, _topup_stock)):
        if now - st[name] >= period:
            st[name] = now
            try:
                what, _ = fn(ctx)
            except Exception as ex:  # noqa: BLE001 - a failed top-up is logged, never the end of a 24-hour run
                what = "%s failed: %s: %s" % (name, type(ex).__name__, ex)
            _hk_log(ctx, what)
            done.append(what)
    return done
