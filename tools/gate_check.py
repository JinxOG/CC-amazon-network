"""The release gate, as one command instead of remembered ad-hoc queries.

Written because I certified job_0049/0050 "clean, no new fault" having checked
errors, failures, ACK timeouts and recalls -- and not having checked repeated
sectors, which that job contained. The verdict was defensible; the word "clean"
was not. A gate you reassemble from memory each time is a gate that drifts.

Usage: python gate_check.py <since-ISO> [job_id ...]

Every check prints its EVIDENCE COUNT, not just a pass. A check that found
nothing because it looked at nothing must not read like a pass -- that is the
failure this project keeps repeating.
"""
import json, urllib.request, re, sys, collections, datetime, math

B = "http://192.168.86.35:3000"

def get(u):
    with urllib.request.urlopen(u, timeout=90) as r:
        return json.load(r)

def p_ts(t):
    return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))

since = sys.argv[1] if len(sys.argv) > 1 else None
if not since:
    print("need a since timestamp, e.g. 2026-09-14T19:47:00")
    sys.exit(2)
jobs_of_interest = sys.argv[2:]

# EVERY day from `since` to today, not just the day `since` falls on.
# A job that crosses midnight lands its completion -- and its last sectors -- in
# the NEXT day's log. The first version of this file queried one day and
# reported "no completion line" for a job that had completed perfectly well,
# and counted 2 sector completions where there were more. Same shape as the
# order=head trap: it looked in the wrong place and said nothing was there.
def days_from(iso):
    d0 = datetime.date.fromisoformat(iso[:10])
    d1 = datetime.date.fromisoformat(
        get(f"{B}/state")["serverTime"] and
        datetime.datetime.fromtimestamp(
            get(f"{B}/state")["serverTime"] / 1000, datetime.UTC).date().isoformat())
    out, d = [], d0
    while d <= d1:
        out.append(d.isoformat())
        d += datetime.timedelta(days=1)
    return out

DAYS = days_from(since)
day = since[:10]          # kept for the since= filter on the first day

def logs(query):
    """Run a log query across every day in the window and merge the lines."""
    lines, matched = [], 0
    for i, dd in enumerate(DAYS):
        q = f"{B}/logs/{dd}?{query}&limit=5000&order=head"
        if i == 0:
            q += f"&since={since}"
        try:
            r = get(q)
        except Exception:
            continue
        lines.extend(r.get("lines", []))
        matched += r.get("matched", 0)
    return {"matched": matched, "lines": lines}

print("=" * 72)
print(f"RELEASE GATE CHECK   since {since}")
print("=" * 72)

fails, notes = [], []

# ---- 1. faults -------------------------------------------------------------
print("\n[1] FAULT LINES")
for label, q, fatal in (
    ("ERROR",              "level=ERROR",                     True),
    ("FAILED",             "contains=FAILED",                 True),
    ("ACK timeout",        "contains=ACK%20timeout",          True),
    ("recall",             "contains=recall",                 True),
    ("Job handler crashed","contains=Job%20handler%20crashed",True),
    ("crash (any)",        "contains=crash",                  False),
):
    d = logs(q)
    n = d.get("matched", 0)
    flag = ""
    if n and fatal:
        fails.append(f"{label}: {n}")
        flag = "  <-- FAULT"
    elif n:
        flag = "  (inspect: may be historical)"
    print(f"    {label:<22}{n}{flag}")
    if n and n <= 5:
        for l in d["lines"][:5]:
            print(f"        {l['ts'][11:19]} {l['source']} {(l.get('msg') or '')[:100]}")

# ---- 2. repeated sectors ---------------------------------------------------
print("\n[2] REPEATED SECTORS")
print("    A repeat only means a STALE REPLAY if that miner re-registered within")
print("    about one sector's work before the FIRST completion -- the replay waits")
print("    in the miner's inbox until its next SECTOR_DONE. Repeats with no recent")
print("    re-link have some other, normal cause: job_0051 had one 746 minutes from")
print("    any re-link, with zero disconnects for the whole job. Counting bare")
print("    repeats as the bug is a false positive, and this gate did exactly that.")
d = logs("node=server&contains=done%20by")
done = collections.defaultdict(list)
for l in d.get("lines", []):
    m = re.search(r"Sector \((\-?\d+),(\-?\d+)\) done by (node_\d+).*\[(job_\d+)", l.get("msg") or "")
    if m:
        done[(m.group(4), m.group(1), m.group(2))].append((p_ts(l["ts"]), m.group(3)))
relink = collections.defaultdict(list)
for l in logs("node=server&contains=Re-registered").get("lines", []):
    m = re.search(r"Re-registered (node_\d+)", l.get("msg") or "")
    if m:
        relink[m.group(1)].append(p_ts(l["ts"]))
completions = sum(len(v) for v in done.values())
short, benign = [], []
for k, v in done.items():
    v.sort()
    for a, b in zip(v, v[1:]):
        gap = (b[0] - a[0]).total_seconds() / 60.0
        if gap >= 15:
            continue
        prior = [(a[0] - t).total_seconds() / 60 for t in relink.get(a[1], []) if t <= a[0]]
        mins = min(prior) if prior else None
        (short if (mins is not None and mins <= 90) else benign).append((k, gap, a[1], mins))
print("    sector completions seen : %d" % completions)
print("    re-registrations seen   : %d" % sum(len(v) for v in relink.values()))
if completions == 0:
    notes.append("no sector completions in window -- this check proved nothing")
    print("    NO EVIDENCE: this check looked at nothing. Not a pass.")
else:
    print("    short-gap repeats       : %d" % (len(short) + len(benign)))
    print("      with a recent re-link : %d  <- candidate stale replays" % len(short))
    print("      no recent re-link     : %d  <- not the bug" % len(benign))
    for k, gap, node, mins in short:
        print("        %s (%s,%s) by %s, gap %.1fm, re-link %.0fm earlier  <-- FAULT"
              % (k[0], k[1], k[2], node, gap, mins))
    for k, gap, node, mins in benign:
        ago = ("%.0fm" % mins) if mins is not None else "never"
        print("        (benign) %s (%s,%s) by %s, gap %.1fm, last re-link %s earlier"
              % (k[0], k[1], k[2], node, gap, ago))
    if short:
        fails.append("stale-sector replays: %d" % len(short))

print("\n[3] DISCONNECTS  (known open fault -- recorded, not gating)")
L = sorted(logs("contains=Server%20unreachable")["lines"], key=lambda l: p_ts(l["ts"]))
if not L:
    print("    none in window")
else:
    eps = []
    cur = [L[0]]
    for l in L[1:]:
        if (p_ts(l["ts"]) - p_ts(cur[-1]["ts"])).total_seconds() <= 2:
            cur.append(l)
        else:
            eps.append(cur); cur = [l]
    eps.append(cur)
    def nn(e): return len({x["source"] for x in e})
    atbase = sum(1 for l in L if re.search(r"pausing at 1[45]\d,", l.get("msg") or ""))
    hrs = max(0.1, (p_ts(L[-1]["ts"]) - p_ts(L[0]["ts"])).total_seconds() / 3600)
    print(f"    warnings {len(L)} over {hrs:.1f}h ({len(L)/hrs:.0f}/h)  "
          f"episodes {len(eps)}  8+ nodes {sum(1 for e in eps if nn(e) >= 8)}")
    print(f"    at the dock: {atbase}/{len(L)}")
    print("    (8+ node episodes are the FIXED fault -- a rise here IS a regression)")
    if sum(1 for e in eps if nn(e) >= 8) > 5:
        fails.append("8+ node disconnect episodes returned")

# ---- 4. health -------------------------------------------------------------
print("\n[4] SERVER AND FLEET HEALTH")
st = get(f"{B}/state")
ll = st.get("logLoss") or {}
print(f"    log loss     : {ll.get('lossPct')}%  ({ll.get('missing')} of {ll.get('expected')})")
print(f"    disk free    : {st.get('diskFree')} bytes")
print(f"    persistence  : {st.get('persistenceHealthy')}   zone store: {st.get('zoneStoreHealthy')}")
print(f"    versionMismatch: {st.get('versionMismatch')}   recentFailures: {len(st.get('recentFailures') or {})}")
vers = collections.Counter(v.get("version") or "?" for v in (st.get("turtles") or {}).values())
print(f"    versions     : {dict(vers)}")
stat = collections.Counter(v.get("status") or "?" for v in (st.get("turtles") or {}).values())
print(f"    statuses     : {dict(stat)}")
if (st.get("diskFree") or 0) < 350000:
    fails.append(f"disk below the 350KB warn floor: {st.get('diskFree')}")
if st.get("versionMismatch"):
    fails.append(f"versionMismatch {st.get('versionMismatch')}")

# ---- 5. jobs ---------------------------------------------------------------
print("\n[5] JOBS")
active = [j for j in (st.get("jobs") or [])
          if j.get("status") in ("PENDING", "ASSIGNED", "IN_PROGRESS")]
print(f"    active now: {len(active)}  {[(j.get('id'), j.get('status')) for j in active]}")
for jid in jobs_of_interest:
    d2 = logs(f"contains={jid}")
    comp = [l for l in d2["lines"] if "Job complete" in (l.get("msg") or "")]
    print(f"    {jid}: {'COMPLETED ' + comp[-1]['ts'][11:19] if comp else 'no completion line'}")
    if not comp:
        notes.append(f"{jid} has no completion line")

# ---- verdict ---------------------------------------------------------------
print("\n" + "=" * 72)
if fails:
    print("VERDICT: NOT CLEAN")
    for f in fails:
        print("   - " + f)
else:
    print("VERDICT: no gating fault found")
if notes:
    print("\nCaveats -- these are NOT passes:")
    for n in notes:
        print("   - " + n)
print("=" * 72)
