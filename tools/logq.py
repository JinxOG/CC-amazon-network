"""Read the live bridge's logs over a time window, safely. Read-only.

Written for the watcher (docs/watcher/README.md), usable by anyone.

    python tools/logq.py --since 2026-10-22T08:24:00Z [--until ISO] [--contains TEXT] [--source server]
                         [--level WARN] [--regex RE] [--count] [--json]

It avoids the two traps in the bridge's /logs (see reference-system-access):
  1. order=head + limit returns the OLDEST lines, so a busy day silently hides new ones. Every query here
     says how many lines the server MATCHED and how many came back; if they differ the result is marked
     TRUNCATED and the exit code is 3. A truncated count is never printed as if it were complete.
  2. Lines are not returned in time order. Everything here is sorted by timestamp before it is printed.

A window can cross midnight; every day from --since to --until (or today) is queried.
"""
import argparse, datetime, json, os, re, sys, urllib.parse, urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

BRIDGE = os.environ.get("BRIDGE_URL", "http://192.168.86.35:3000")
PAGE = 5000


def parse_ts(s):
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    t = datetime.datetime.fromisoformat(s)
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t


def days(since, until):
    d, out = since.date(), []
    while d <= until.date():
        out.append(d.isoformat())
        d += datetime.timedelta(days=1)
    return out


def fetch(day, params, get=None):
    get = get or (lambda u: json.load(urllib.request.urlopen(u, timeout=90)))
    q = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
    return get(f"{BRIDGE}/logs/{day}?{q}")


def query(since, until, contains=None, source=None, level=None, regex=None, get=None):
    """Returns (lines sorted by time, truncated?, per-day notes)."""
    lines, truncated, notes = [], False, []
    rx = re.compile(regex) if regex else None
    for i, day in enumerate(days(since, until)):
        params = {"contains": contains, "node": source, "level": level, "limit": PAGE, "order": "head",
                  "since": since.isoformat().replace("+00:00", "Z") if i == 0 else None}
        try:
            r = fetch(day, params, get)
        except Exception as e:  # a missing day file is normal; anything else is reported
            notes.append(f"{day}: no data ({type(e).__name__})")
            continue
        got = r.get("lines", [])
        if r.get("matched", len(got)) > len(got):
            truncated = True
            notes.append(f"{day}: server matched {r.get('matched')} but returned {len(got)}")
        for l in got:
            t = parse_ts(l["ts"])
            if t < since or t > until:
                continue
            if source and l.get("source") != source:
                continue
            if rx and not rx.search(l.get("msg", "")):
                continue
            lines.append(l)
    lines.sort(key=lambda l: (parse_ts(l["ts"]), l.get("seq", 0)))
    return lines, truncated, notes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--since", required=True)
    ap.add_argument("--until")
    ap.add_argument("--contains")
    ap.add_argument("--source", help="exact source, e.g. server, warehouse, node_183")
    ap.add_argument("--level")
    ap.add_argument("--regex", help="applied to the message after the server-side filters")
    ap.add_argument("--count", action="store_true", help="print only the count")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    since = parse_ts(a.since)
    until = parse_ts(a.until) if a.until else datetime.datetime.now(datetime.timezone.utc)
    lines, truncated, notes = query(since, until, a.contains, a.source, a.level, a.regex)
    head = (f"window {since.isoformat()} .. {until.isoformat()}  filters: contains={a.contains!r} "
            f"source={a.source!r} level={a.level!r} regex={a.regex!r}")
    if a.json:
        print(json.dumps({"window": [since.isoformat(), until.isoformat()], "count": len(lines),
                          "truncated": truncated, "notes": notes, "lines": [] if a.count else lines}))
    else:
        print(head)
        for n in notes:
            print("NOTE", n)
        if not a.count:
            for l in lines:
                print(f"{l['ts']}  {l.get('source', '?'):<12} {l.get('level', '-'):<5} {l.get('msg', '')}")
        print(f"COUNT {len(lines)}" + ("  ** TRUNCATED: the true count is higher; narrow the filter **" if truncated else ""))
    return 3 if truncated else 0


if __name__ == "__main__":
    sys.exit(main())
