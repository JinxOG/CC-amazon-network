"""W3, 2026-11-05: is the arrivals lane at z -2801 in a chunk that does not tick? In w3-atc-pair-split-a and -b the delivery
node_96 stepped from 228,67,-2800 to 228,67,-2801 (the first block of chunk z -176), started a turn, and its computer received
NO events at all for exactly 3 minutes (t2control events.jsonl), then booted again. That is what a turtle in a chunk that is
loaded but not ticking looks like. Probe: a computer on each side of the chunk edge, each running a 1 s timer loop; the event
log says which one runs. Also asks the game `execute if loaded` for both blocks and their neighbours. No fleet change.
Run with --t2logs. 1x, a few minutes."""
import os
import tempfile

NAME = "w3_chunk_tick_probe"
TICKER = 'local n = 0\nwhile true do n = n + 1; os.startTimer(1); os.pullEvent("timer") end\n'
# 160,67,-2790 is the CONTROL: the ATC computer started there in w3-atc-pair-c. Then a walk toward the frozen block.
SPOTS = [(160, 67, -2790), (200, 67, -2790), (220, 67, -2790), (226, 67, -2786), (226, 67, -2795), (226, 67, -2801), (228, 67, -2801)]


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    for (x, y, z) in SPOTS:
        ctx.note("execute if loaded %d %d %d -> %s" % (x, y, z, c.command("execute if loaded %d %d %d" % (x, y, z)).strip()[:80]))
        ctx.note("block at %d %d %d is air: %s" % (x, y, z, c.command("execute if block %d %d %d air" % (x, y, z)).strip()[:60]))
    tmp = tempfile.mkdtemp(prefix="w3tick")
    start = os.path.join(tmp, "startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(TICKER)
    ids = {}
    for (x, y, z) in SPOTS:
        if "Test passed" not in c.command("execute if block %d %d %d air" % (x, y, z)):
            ctx.note("skip %d,%d,%d: not air" % (x, y, z))
            continue
        try:
            ids[(x, y, z)] = c.spawn_computer(x, y, z, start, modem=False)
        except Exception as e:  # noqa: BLE001 - a refused spot is itself a finding
            ctx.note("spawn at %d,%d,%d refused: %s" % (x, y, z, e))
    ctx.note("probe computers: %s" % {"%d,%d,%d" % k: v for k, v in ids.items()})
    ctx.wait_game(60)
    import json
    path = os.path.join(ctx.run, "t2control", "events.jsonl")
    counts = {v: 0 for v in ids.values()}
    if os.path.exists(path):
        with open(path, encoding="utf8", errors="replace") as h:
            for line in h:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("computer") in counts and e.get("event") == "timer":
                    counts[e["computer"]] += 1
    for k, v in ids.items():
        ctx.note("computer #%d at %d,%d,%d: %d timer events in 60 s" % (v, k[0], k[1], k[2], counts[v]))
    ctx.expect(bool(ids), "probe computers placed (%d)" % len(ids))
    ctx.expect(path and os.path.exists(path), "the event log is on (run with --t2logs)")
    c.shutdown(list(ids.values()))
