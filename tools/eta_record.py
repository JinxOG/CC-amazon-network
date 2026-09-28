"""Record what the ETA says against the wall clock, for a whole mining job.

This is the instrument that caught the 1.9.117 ETA reading 191 minutes for two
and a half hours while the turtles dug 8,344 ore out of the ground. It is
deliberately dumb: poll the number the dashboard itself publishes, write it down
with the time, and let the job's real completion decide who was right.

Two things it must do that the first version did not:
  * write every sample to disk as it takes it, because the first recorder lived
    only in a session's scrollback and died with the session;
  * write a machine-readable copy too, so the error at each sample is computed
    rather than eyeballed off a table.

A live zone in /state carries status "ACTIVE", its phase, and `eta` in SECONDS.

Usage:  python tools/eta_record.py [--out DIR] [--every SECONDS]

Stops once a job has been seen and then no live zone remains for three polls.
"""

import argparse
import json
import os
import time
import urllib.request

STATE = "http://192.168.86.35:3000/state"
ACTIVE_JOB = ("IN_PROGRESS", "PENDING", "QUEUED", "ASSIGNED")


def fetch():
    with urllib.request.urlopen(STATE, timeout=30) as r:
        return json.load(r)


def as_list(v):
    return list(v.values()) if isinstance(v, dict) else (v or [])


def ore_total(d):
    return sum(int(n or 0) for n in (d or {}).values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=".")
    ap.add_argument("--every", type=int, default=300)
    a = ap.parse_args()

    stamp = time.strftime("%Y%m%d-%H%M%S")
    txt = os.path.join(a.out, "eta-record-%s.txt" % stamp)
    jsl = os.path.join(a.out, "eta-record-%s.jsonl" % stamp)
    with open(txt, "w", encoding="utf-8") as f:
        f.write("when     | job      | phase  done  surv   resc | eta_min |"
                " ore out | ore found\n")
    print("recording to", txt)

    seen_job, empty = False, 0

    while True:
        try:
            st = fetch()
        except Exception as e:                    # the bridge is allowed to blink
            with open(txt, "a", encoding="utf-8") as f:
                f.write("%s | FETCH FAILED: %s\n" % (time.strftime("%H:%M:%S"), e))
            time.sleep(a.every)
            continue

        now_hms = time.strftime("%H:%M:%S")
        now_iso = time.strftime("%Y-%m-%dT%H:%M:%S")
        jobs = [j for j in as_list(st.get("jobs")) if (j.get("status") or "") in ACTIVE_JOB]
        zones = {k: z for k, z in (st.get("mineZones") or {}).items()
                 if z.get("status") == "ACTIVE"}

        if zones or jobs:
            seen_job, empty = True, 0
        elif seen_job:
            empty += 1

        rows = []
        for jid, z in sorted(zones.items()):
            eta = z.get("eta")
            rows.append({
                "t": now_iso, "job": jid, "phase": z.get("phase"),
                "done": z.get("done"), "total": z.get("total"),
                "surveyDone": z.get("surveyDone"), "surveyTotal": z.get("surveyTotal"),
                "rescanDone": z.get("rescanDone"), "rescanTotal": z.get("rescanTotal"),
                "eta_s": eta if isinstance(eta, (int, float)) else None,
                "ore_out": ore_total(z.get("oreMined")),
                "ore_found": ore_total(z.get("oreFound")),
                "minerId": z.get("minerId"), "minerStatus": z.get("minerStatus"),
            })
        if not rows:
            rows = [{"t": now_iso, "job": None,
                     "jobs": [(j.get("id"), j.get("status")) for j in jobs]}]

        with open(jsl, "a", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")

        with open(txt, "a", encoding="utf-8") as f:
            for r in rows:
                if r["job"] is None:
                    f.write("%s | %s\n" % (now_hms, r["jobs"] or "(no live zone, no jobs)"))
                else:
                    e = r["eta_s"]
                    f.write("%s | %-8s | %-6s %d/%-3s %s/%-3s %s/%-3s | %7s | %7d | %8d\n" % (
                        now_hms, r["job"], (r["phase"] or "?")[:6],
                        r["done"] or 0, r["total"],
                        r["surveyDone"], r["surveyTotal"],
                        r["rescanDone"], r["rescanTotal"],
                        ("%.1f" % (e / 60.0)) if isinstance(e, (int, float)) else "-",
                        r["ore_out"], r["ore_found"]))

        if seen_job and empty >= 3:
            with open(txt, "a", encoding="utf-8") as f:
                f.write("%s | the job is gone and no zone is live - recording ends\n" % now_hms)
            print("done:", txt)
            return

        time.sleep(a.every)


if __name__ == "__main__":
    main()
