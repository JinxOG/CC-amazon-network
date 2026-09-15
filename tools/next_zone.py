"""Pick the next mine point, and prove it is what we think before dispatching.

Three things have to hold, and two of them have already gone wrong once:

1. FOUR SECTORS, not two. The server rounds the point down and up to 32-block
   boundaries (buildSectorGrid, SECTOR_STEP=32). A coordinate that is an exact
   multiple of 32 makes floor == ceil, that axis collapses, and the zone is half
   the size. Sector count then sets miner count -- 1 miner per 3 sectors -- so a
   collapsed axis quietly costs a miner too. That is how job_0051 ended up as a
   2-sector, 1-miner job.

2. FRESH GROUND. Older chunks do not work because of the depth change, so the
   zone must not touch anything already worked -- with a margin, not just a
   non-overlap, because sharing an exact boundary re-works a column.

3. It should be near the recent working area, so travel stays sane.

Prints the reasoning for each rejection rather than just the answer, because the
answer is the thing that has been wrong.
"""
import json, urllib.request, re, math

B = "http://192.168.86.35:3000"
STEP = 32
MARGIN = 16          # blocks of clearance required from any worked zone
WANT_SECTORS = 4

def get(u):
    with urllib.request.urlopen(u, timeout=60) as r:
        return json.load(r)

def sector_box(x, z):
    minX = math.floor(x / STEP) * STEP
    maxX = math.ceil(x / STEP) * STEP
    minZ = math.floor(z / STEP) * STEP
    maxZ = math.ceil(z / STEP) * STEP
    nx = len(range(minX, maxX + 1, STEP))
    nz = len(range(minZ, maxZ + 1, STEP))
    return nx * nz, (minX, minZ, maxX, maxZ)

st = get(f"{B}/state")
worked = []
for k, v in (st.get("mineZones") or {}).items():
    m = re.match(r"zone:(-?\d+),(-?\d+),(-?\d+),(-?\d+)", str(k))
    if m:
        worked.append(tuple(int(q) for q in m.groups()))
        continue
    # A RUNNING job is keyed by its job id, not "zone:", and the first version of
    # this file skipped those entirely -- so it happily proposed a zone on top of
    # the job that was mining at that moment. Its bounds are on the entry.
    b = v.get("bounds") or v.get("rawBounds")
    if b:
        worked.append((b["x1"], b["z1"], b["x2"], b["z2"]))
        print(f"  (including LIVE zone {k}: x {b['x1']}..{b['x2']} z {b['z1']}..{b['z2']})")

def clear_of_worked(box):
    x1, z1, x2, z2 = box
    for (bx1, bz1, bx2, bz2) in worked:
        if not (x2 + MARGIN < bx1 or bx2 < x1 - MARGIN
                or z2 + MARGIN < bz1 or bz2 < z1 - MARGIN):
            return False, (bx1, bz1, bx2, bz2)
    return True, None

print(f"worked zones known to the server: {len(worked)}")
print(f"looking for a point giving {WANT_SECTORS} sectors, {MARGIN} blocks clear\n")

anchor = (1964, -3000)          # near the current job, off the boundary
best, rejected = None, []
for dx in range(0, 400, 8):
    for sx in (1, -1):
        for dz in range(0, 400, 8):
            for sz in (1, -1):
                x, z = anchor[0] + sx * dx, anchor[1] + sz * dz
                n, box = sector_box(x, z)
                if n != WANT_SECTORS:
                    rejected.append((x, z, f"{n} sectors"))
                    continue
                ok, hit = clear_of_worked(box)
                if not ok:
                    rejected.append((x, z, f"touches {hit}"))
                    continue
                d = (x - anchor[0]) ** 2 + (z - anchor[1]) ** 2
                if best is None or d < best[0]:
                    best = (d, x, z, box)

print(f"candidates rejected: {len(rejected)}  (first few: "
      + "; ".join(f"{r[0]},{r[1]} {r[2]}" for r in rejected[:3]) + ")")
if best:
    _, x, z, box = best
    n, _ = sector_box(x, z)
    print(f"\nCHOSEN: {x},{z}")
    print(f"   sectors      : {n}")
    print(f"   zone covers  : x {box[0]}..{box[2]}   z {box[1]}..{box[3]}")
    print(f"   on boundary? : x {'YES' if x % STEP == 0 else 'no'}, "
          f"z {'YES' if z % STEP == 0 else 'no'}")
    # ceil, not floor: job_0049 had 4 sectors and got TWO jobs ("[1/2]"),
    # job_0051 had 2 and got one. 4//3 would predict 1 and be wrong.
    miners = max(1, -(-n // 3))
    print(f"   expect       : {n} sectors -> {miners} miner(s) "
          f"(server rule: 1 per 3 sectors, rounded UP)")
else:
    print("\nNO CANDIDATE FOUND - widen the search rather than dispatching anyway.")
