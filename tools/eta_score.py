import json, io, sys
from datetime import datetime

JSL = sys.argv[1]
END = datetime(2026, 9, 28, 0, 23, 56)      # job_0088 complete, local clock

rows = []
seen = set()
for line in io.open(JSL, encoding="utf-8"):
    r = json.loads(line)
    if not r.get("job") or r.get("eta_s") is None:
        continue
    if r["t"] in seen:            # two jobs share one zone: identical numbers
        continue
    seen.add(r["t"])
    t = datetime.fromisoformat(r["t"])
    left = (END - t).total_seconds() / 60.0
    rows.append((t, r["phase"], r["eta_s"] / 60.0, left, r["ore_out"], r["done"],
                 r["rescanDone"], r["rescanTotal"]))

print("  clock | phase  | said  | actual |  err  | +13min |  ore out")
print("--------+--------+-------+--------+-------+--------+---------")
for t, ph, said, left, ore, done, rd, rt in rows:
    print("  %s | %-6s | %5.0f | %6.0f | %+5.0f | %+6.0f | %7d" % (
        t.strftime("%H:%M"), ph, said, left, said - left, said + 13 - left, ore))

mine = [r for r in rows if r[1] == "MINE" and r[3] > 40]
err = [r[2] - r[3] for r in mine]
adj = [r[2] + 13 - r[3] for r in mine]
print()
print("mine-phase samples with over 40 min to go, n = %d" % len(mine))
print("  as shipped (1.9.118):  mean %+.1f min, worst %+.1f, mean |err| %.1f"
      % (sum(err) / len(err), max(err, key=abs), sum(abs(e) for e in err) / len(err)))
print("  with a 13 min flight home priced in: mean %+.1f min, worst %+.1f, mean |err| %.1f"
      % (sum(adj) / len(adj), max(adj, key=abs), sum(abs(e) for e in adj) / len(adj)))
