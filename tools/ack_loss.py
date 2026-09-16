"""Per-turtle acknowledgement loss, split working vs parked, with a time trend.

The channel change is judged on this table (spec owner, 2026-09-16):

  parked loss at or below the working-miner level (~1.1%)  -> fix confirmed
  falls, but stays well above                              -> partial; new card
  no material change                                       -> prediction failed; stop

Loss is ACKS SEEN against BEATS SENT, from each turtle's own `loop baseline`
line. The server ACKs every heartbeat from a known turtle exactly once, so a
shortfall is loss measured on the turtle, with no fleet-size assumption.

CLASSIFICATION IS PER LINE, NOT PER NODE. The first version called a node
"working" for the whole window if it accepted a job at any point in it. On
1.9.106 node_138 and node_139 mined for ~9 hours and then sat parked for ~5, and
all of it was scored as working -- which dragged the working figure from 1.07%
to 6.30% and made the split meaningless. Each baseline line is now classed by
whether that node held a job AT THAT LINE'S TIME, from the server's own
"accepted by" and "Job complete" lines.

THE TREND IS PRINTED because a single number over a long window hides drift, and
the first 3 hours of 1.9.106 read very differently from the whole 14.

Usage:  python tools/ack_loss.py <since-ISO> [until-ISO]
"""
import json, urllib.request, re, sys, statistics, collections, datetime

B = "http://192.168.86.35:3000"

def get(u):
    with urllib.request.urlopen(u, timeout=90) as r:
        return json.load(r)

def ts(t):
    return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))

if len(sys.argv) < 2:
    print("usage: ack_loss.py <since-ISO> [until-ISO]")
    sys.exit(2)
since = sys.argv[1]
t0 = datetime.datetime.fromisoformat(since + "+00:00")
now = datetime.datetime.fromtimestamp(get(f"{B}/state")["serverTime"] / 1000, datetime.UTC)
t1 = datetime.datetime.fromisoformat(sys.argv[2] + "+00:00") if len(sys.argv) > 2 else now

days, d = [], t0.date()
while d <= t1.date():
    days.append(d.isoformat()); d += datetime.timedelta(days=1)

def logs(q, lookback_hours=0):
    """All lines matching q in [t0 - lookback, t1]. Refuses capped results."""
    start = (t0 - datetime.timedelta(hours=lookback_hours))
    ds, dd = [], start.date()
    while dd <= t1.date():
        ds.append(dd.isoformat()); dd += datetime.timedelta(days=1)
    out = []
    for i, day in enumerate(ds):
        u = f"{B}/logs/{day}?{q}&limit=5000&order=head"
        if i == 0:
            u += "&since=" + start.strftime("%Y-%m-%dT%H:%M:%S")
        r = get(u)
        lines = r.get("lines", [])
        # Never do arithmetic on a capped result -- the trap that produced a
        # false "zero" on 2026-09-15.
        if len(lines) >= 5000:
            print(f"REFUSING: {day} returned 5000 lines ({q}), the cap. Narrow the window.")
            sys.exit(3)
        out.extend(l for l in lines if ts(l["ts"]) <= t1)
    return out

# ---- job windows per node --------------------------------------------------
# Look back far enough to catch a job accepted before the window opened.
acc = logs("node=server&contains=accepted%20by", lookback_hours=24)
comp = logs("node=server&contains=Job%20complete", lookback_hours=24)
job_node, job_start, job_end = {}, {}, {}
for l in acc:
    m = re.search(r"Job (job_\d+) accepted by (node_\d+)", l.get("msg") or "")
    if m:
        job_node[m.group(1)] = m.group(2)
        job_start[m.group(1)] = ts(l["ts"])       # latest acceptance wins (retries)
for l in comp:
    m = re.search(r"Job complete: (job_\d+)", l.get("msg") or "")
    if m:
        job_end[m.group(1)] = ts(l["ts"])
windows = collections.defaultdict(list)
for j, n in job_node.items():
    windows[n].append((job_start[j], job_end.get(j, t1)))

def working_at(node, when):
    return any(a <= when <= b for a, b in windows.get(node, []))

# ---- baseline lines --------------------------------------------------------
per = collections.defaultdict(lambda: {"working": [0, 0], "parked": [0, 0], "turns": []})
hourly = collections.defaultdict(lambda: {"working": [0, 0], "parked": [0, 0]})
n_lines = 0
for l in logs("contains=loop%20baseline"):
    m = re.search(r"loop baseline: ([\d.]+) turns/s, ([\d.]+) msgs/s handled, "
                  r"(\d+) acks for (\d+) beats", l.get("msg") or "")
    if not m:
        continue
    n_lines += 1
    when, node = ts(l["ts"]), l["source"]
    grp = "working" if working_at(node, when) else "parked"
    a, b = int(m.group(3)), int(m.group(4))
    per[node][grp][0] += a; per[node][grp][1] += b
    per[node]["turns"].append(float(m.group(1)))
    hb = hourly[when.strftime("%m-%d %H:00")][grp]
    hb[0] += a; hb[1] += b

if not n_lines:
    print("NO BASELINE LINES in the window. No verdict.")
    sys.exit(2)

def pct(a, b):
    return f"{100*(b-a)/b:5.1f}%" if b else "   - "

print(f"window: {t0:%Y-%m-%d %H:%M} to {t1:%Y-%m-%d %H:%M} UTC  "
      f"({(t1-t0).total_seconds()/3600:.1f} h, {n_lines} baseline lines)")
print(f"\n{'node':<11}{'turns/s':>8}   {'working acks/beats':>20}{'loss':>7}"
      f"   {'parked acks/beats':>19}{'loss':>7}")
tot = {"working": [0, 0], "parked": [0, 0]}
for n, r in sorted(per.items(), key=lambda kv: -statistics.median(kv[1]["turns"])):
    for g in ("working", "parked"):
        tot[g][0] += r[g][0]; tot[g][1] += r[g][1]
    w, pk = r["working"], r["parked"]
    print(f"{n:<11}{statistics.median(r['turns']):>8.2f}   "
          f"{(str(w[0])+'/'+str(w[1])) if w[1] else '-':>20}{pct(*w):>7}   "
          f"{(str(pk[0])+'/'+str(pk[1])) if pk[1] else '-':>19}{pct(*pk):>7}")

print()
for g in ("working", "parked"):
    a, b = tot[g]
    print(f"{g.upper():<8}: {a} acks / {b} beats -> "
          + (f"{100*(b-a)/b:.2f}% lost" if b else "no beats"))

print("\nhourly trend (loss %):")
print(f"   {'hour':<12}{'working':>9}{'parked':>9}")
for h in sorted(hourly):
    print(f"   {h:<12}{pct(*hourly[h]['working']):>9}{pct(*hourly[h]['parked']):>9}")
