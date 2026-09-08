# Reading the fleet log — procedure for every agent

- **Date:** 2026-09-08
- **Author:** W3 — Fleet & Dispatch
- **Audience:** every workstream. This is a reference, not a proposal.
- **Applies from:** proto 1.9.86 / bridge `bf65188`

---

## What exists

Every `print()` on every turtle, and every log line on the dispatch server, is
written to a plain text file on the bridge host and served over HTTP.

```
file      ~/cc-dashboard/logs/YYYY-MM-DD.txt   on 192.168.86.35
rotation  daily, 14-day retention
volume    ~10 MB/day with two miners working
```

**Do not read that file over SSH and do not ask the operator for it.** It is
served, and the served form filters server-side so you fetch kilobytes instead of
megabytes.

## The two endpoints

```bash
# What days exist, and how big
curl -s http://192.168.86.35:3000/logs

# Query one day
curl -s "http://192.168.86.35:3000/logs/2026-09-08?node=node_119&level=WARN&limit=200"
```

| Parameter | Meaning |
|---|---|
| `node` | exact source: a node id, or `server` for the dispatch server |
| `level` | `INFO` / `WARN` / `ERROR` |
| `contains` | substring of the message |
| `since`, `until` | ISO-8601, and a prefix works: `2026-09-08T14` is a valid hour bound |
| `limit` | default 500, hard ceiling 5000 |
| `order` | `tail` (default, newest) or `head` (oldest) |
| `format` | `json` (default) or `text` |

Response:

```jsonc
{
  "file": "2026-09-08.txt",
  "matched": 1244,      // BEFORE the limit
  "returned": 500,
  "truncated": true,
  "lines": [ { "ts": "...", "source": "node_118", "level": "INFO", "msg": "..." } ]
}
```

**`matched` is the number that stops you being wrong.** `returned` is a slice.
If `truncated` is true and you draw a conclusion from `lines` alone, you are
reasoning about the tail of the evidence and calling it the evidence.

## Worked examples

```bash
# Is one node misbehaving, and since when?
curl -s "http://192.168.86.35:3000/logs/2026-09-08?node=node_119&limit=100&format=text"

# Everything that went wrong today, both sides
curl -s "http://192.168.86.35:3000/logs/2026-09-08?level=WARN&limit=1000" | python3 -c "
import sys,json,collections
d=json.load(sys.stdin)
print(d['matched'],'matched;',d['returned'],'returned')
for m,n in collections.Counter(l['msg'][:60] for l in d['lines']).most_common(15):
    print(f'{n:5d}  {m}')"

# Count an event per node, which is how you tell fleet-wide from one-node
curl -s "http://192.168.86.35:3000/logs/2026-09-08?contains=Registering&limit=5000" | python3 -c "
import sys,json,collections
d=json.load(sys.stdin)
print(collections.Counter(l['source'] for l in d['lines']))"

# A one-hour window around something you already know the time of
curl -s "http://192.168.86.35:3000/logs/2026-09-08?since=2026-09-08T00:43&until=2026-09-08T00:50&format=text"
```

## Rules

1. **Filter server-side.** `?node=` and `?contains=` run against a stream on the
   bridge. Fetching everything and grepping locally pulls megabytes through a
   process that has a job to do.

2. **Do not poll it in a tight loop.** This bridge answers the dispatch server
   every 3 seconds, and that server is synchronous: time the bridge spends busy
   is time the CC server waits, and a CC server waiting is one deaf to its own
   radio. That is the mechanism behind every dropped heartbeat this system has
   had. A few queries while diagnosing is nothing. A poll every second is not.

3. **Quote `matched`, not just what you read.** See above.

4. **Timestamps are ISO-8601 in UTC** and sort lexicographically, so string
   comparison is time comparison. The in-game clock in screenshots is not.

## What the log does NOT contain

State these when you use it, rather than letting a reader assume completeness.

- **Bursts from before 1.9.85.** Only the last 10 lines per node per push were
  ever shipped, so a turtle printing more than that between pushes lost the rest
  before the bridge saw them. Boot sequences did exactly this. From 1.9.85 the
  server sends a delta and this gap is closed.
- **The warehouse and admin computers.** They forward nothing at all. If you need
  them, that is Phase 3 and nobody has built it.
- **Anything printed while a node is off the air** — a miner's deliberate comms
  gap during the loader swap, or any computer between crash and reboot.
- **Anything before the bridge's log directory existed** (first written
  2026-09-08).

## If a query returns nothing

In this order, because each rules out the next:

1. `curl -s http://192.168.86.35:3000/logs` — is the day there at all?
2. Drop every filter and re-query with `?limit=5`. Empty means the file is
   empty, not that your filter is wrong.
3. `curl -s http://192.168.86.35:3000/state | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['version'],d.get('versionMismatch'))"`
   — a bridge that is up but a CC server that is not pushing looks identical to
   a quiet fleet from here.
4. Only then suspect the log pipeline.

## Access from outside the LAN

The LAN address needs no credentials. The ngrok tunnel requires basic auth and
the `ngrok-skip-browser-warning: true` header on every request. Prefer the LAN
address; the tunnel is slower and gated for no benefit from inside.
