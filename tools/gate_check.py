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
    # Its own check, fatal. These were hiding under the loose "crash" search
    # below, labelled "may be historical" beside genuine boot-time lines.
    # The SERVER's job-retry line specifically ("Job job_0052 retry 1/3: ..."),
    # not any line containing "retry". The broad version flagged a turtle
    # retrying a loader-beacon check -- benign, routine, and a false NOT CLEAN.
    # Widening a check to catch one real fault and then trusting it is how a
    # gate starts crying wolf, which ends in its verdicts being ignored.
    ("job retry",          "node=server&contains=%20retry%20",  True),
    ("idle-stuck rescue",  "contains=Idle-stuck",             True),
    ("sector returned",    "contains=returned%20to%20pending", True),
    # 1.9.110: a zone whose miners all ended with sectors still to do. A
    # replacement is queued, but the zone did not finish on what it was given.
    ("zone left unmined",  "node=server&contains=unmined%20sector", True),
    # Kept last and non-fatal ON PURPOSE: the server logs its crash-log summary
    # at every boot, so this matches old news by design. Anything it catches
    # that the fatal checks above did not is worth a human glance, nothing more.
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
print("    re-link are a different fault, not a normal event: up to 1.9.108 a miner")
print("    could hold two copies of one order (both turtle loops filed it), so it")
print("    ran the sector twice back to back. That is section [2b], fixed in 1.9.109.")
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
    print("      no recent re-link     : %d  <- not a replay; see [2b]" % len(benign))
    for k, gap, node, mins in short:
        print("        %s (%s,%s) by %s, gap %.1fm, re-link %.0fm earlier  <-- FAULT"
              % (k[0], k[1], k[2], node, gap, mins))
    for k, gap, node, mins in benign:
        ago = ("%.0fm" % mins) if mins is not None else "never"
        print("        (benign) %s (%s,%s) by %s, gap %.1fm, last re-link %s earlier"
              % (k[0], k[1], k[2], node, gap, ago))
    if short:
        fails.append("stale-sector replays: %d" % len(short))

print("\n[2b] FIRST ORDER DOUBLED  (release A, 1.9.109: must be 0)")
print("    Up to 1.9.108 every miner held a spare copy of its first sector order,")
print("    so its first sector was reported done twice in a row (21 of 22 jobs,")
print("    job_0037..job_0059). Only jobs ACCEPTED inside the window are judged:")
print("    for a job that started earlier, the window does not show its first order.")
started = set()
for l in logs("node=server&contains=accepted%20by").get("lines", []):
    m = re.search(r"Job (job_\d+) accepted by (node_\d+)", l.get("msg") or "")
    if m:
        started.add((m.group(1), m.group(2)))
firsts = collections.defaultdict(list)
for l in d.get("lines", []):
    m = re.search(r"(?:Survey|Sector|Rescan) \((\-?\d+),(\-?\d+)\) done by (node_\d+).*\[(job_\d+)",
                  l.get("msg") or "")
    if m and (m.group(4), m.group(3)) in started:
        firsts[(m.group(4), m.group(3))].append((p_ts(l["ts"]), m.group(1) + "," + m.group(2)))
judged = doubled = 0
for k, v in sorted(firsts.items()):
    v.sort()
    if len(v) < 2:
        continue
    judged += 1
    if v[0][1] == v[1][1]:
        doubled += 1
        print("        %s %s first sector (%s) done twice, %.1fm apart  <-- FAULT"
              % (k[0], k[1], v[0][1], (v[1][0] - v[0][0]).total_seconds() / 60))
print("    job/miner pairs judged  : %d" % judged)
print("    first order doubled     : %d" % doubled)
if judged == 0:
    notes.append("no job started in window with two completions -- [2b] proved nothing")
    print("    NO EVIDENCE: no job started in this window. Not a pass.")
if doubled:
    fails.append("first order doubled: %d of %d" % (doubled, judged))

print("\n[2c] LATE COMPLETIONS  (release B, 1.9.110: its evidence)")
print("    A completion whose order was handed out in another phase than the zone")
print("    is in now. B counts it by the phase it was handed out in and logs it.")
print("    A job validating B counts only if at least one appears.")
late = sorted(logs("node=server&contains=Late%20completion").get("lines", []),
              key=lambda l: l["ts"])
for l in late[:10]:
    print("        %s %s" % (l["ts"][11:19], (l.get("msg") or "")[:120]))
print("    late completions        : %d" % len(late))
if not late:
    notes.append("[2c] no late completion in window -- release B's fix was not exercised")

print("\n[2d] ONE SECTOR, TWO MINERS  (fatal, any phase)")
print("    A miner holds a sector from the moment it takes the order until it")
print("    reports that sector done, takes another order, or is sent MINE_COMPLETE.")
print("    Two holds on one sector that overlap in time are a fault. Rebuilt twice:")
print("      server view -- its 'Assigned sector' lines (every hand-out from 1.9.110)")
print("      miner view  -- TRAVELLING to a sector, what the miner actually set out")
print("                     to do (server phase lines + the miner's own; can undercount)")
ends = []
for l in d.get("lines", []):
    m = re.search(r"\((\-?\d+),(\-?\d+)\) done by (node_\d+)", l.get("msg") or "")
    if m:
        ends.append((p_ts(l["ts"]), "done", m.group(3), m.group(1) + "," + m.group(2)))
for l in logs("node=server&contains=MINE_COMPLETE%20to").get("lines", []):
    m = re.search(r"MINE_COMPLETE to (node_\d+)", l.get("msg") or "")
    if m:
        ends.append((p_ts(l["ts"]), "end", m.group(1), ""))
# A job that ends ends its miner's hold, however it ended.
job_node = {}
for l in logs("node=server&contains=accepted%20by").get("lines", []):
    m = re.search(r"Job (job_\d+) accepted by (node_\d+)", l.get("msg") or "")
    if m:
        job_node[m.group(1)] = m.group(2)
for l in logs("node=server&contains=job_").get("lines", []):
    m = re.search(r"Job (?:complete|permanently failed): (job_\d+)", l.get("msg") or "")
    if m and m.group(1) in job_node:
        ends.append((p_ts(l["ts"]), "end", job_node[m.group(1)], ""))

def overlapping(starts):
    """starts: (ts, node, sector). Returns (holds, clashes)."""
    ev = sorted([(t, "start", n, s) for t, n, s in starts] + ends,
                key=lambda e: (e[0], 1 if e[1] == "start" else 0))
    open_hold, holds = {}, []
    for t, kind, node, sec in ev:
        cur = open_hold.get(node)
        if cur and (kind in ("start", "end") or sec == cur[1]):
            holds.append((node, cur[1], cur[0], t))
            del open_hold[node]
        if kind == "start":
            open_hold[node] = (t, sec)
    last = max([e[0] for e in ev], default=None)
    for node, (t, sec) in open_hold.items():
        holds.append((node, sec, t, last))
    clashes = [(a, b) for i, a in enumerate(holds) for b in holds[i + 1:]
               if a[1] == b[1] and a[0] != b[0] and a[2] < b[3] and b[2] < a[3]]
    return holds, clashes

views = {}
srv = []
for l in logs("node=server&contains=Assigned%20sector").get("lines", []):
    m = re.search(r"Assigned sector \((\-?\d+),(\-?\d+)\).* to (node_\d+)", l.get("msg") or "")
    if m:
        srv.append((p_ts(l["ts"]), m.group(3), m.group(1) + "," + m.group(2)))
views["server view"] = srv
# Two sources for the same moment: the server's phase line (only when the
# phase CHANGES, so a TRAVELLING -> TRAVELLING order is missing) and the miner's
# own shipped line (lost in comms gaps). Union, one start per node per sector
# within 5 s.
mnr, seen = [], {}
for l in logs("contains=phase%20TRAVELLING").get("lines", []):
    msg = l.get("msg") or ""
    m = re.search(r"(node_\d+) phase: TRAVELLING \(sector (\-?\d+),(\-?\d+)\)", msg)
    if m:
        node, sec = m.group(1), m.group(2) + "," + m.group(3)
    else:
        m = re.search(r"\[MINER\] phase TRAVELLING \S+ sector (\-?\d+),(\-?\d+)", msg)
        if not (m and re.match(r"node_\d+$", l.get("source") or "")):
            continue
        node, sec = l["source"], m.group(1) + "," + m.group(2)
    t = p_ts(l["ts"])
    prev = seen.get((node, sec))
    if prev and any(abs((t - x).total_seconds()) <= 5 for x in prev):
        continue
    seen.setdefault((node, sec), []).append(t)
    mnr.append((t, node, sec))
views["miner view"] = mnr
for name, starts in views.items():
    holds, clashes = overlapping(starts)
    print("    %-12s holds %3d   overlapping %d" % (name, len(holds), len(clashes)))
    for a, b in clashes[:6]:
        print("        (%s) %s %s-%s  and  %s %s-%s  <-- FAULT"
              % (a[1], a[0], a[2].strftime("%H:%M"), a[3].strftime("%H:%M"),
                 b[0], b[2].strftime("%H:%M"), b[3].strftime("%H:%M")))
    if not holds:
        notes.append("[2d] %s: no holds in window -- proved nothing" % name)
    if clashes:
        fails.append("sector held by two miners (%s): %d" % (name, len(clashes)))

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
