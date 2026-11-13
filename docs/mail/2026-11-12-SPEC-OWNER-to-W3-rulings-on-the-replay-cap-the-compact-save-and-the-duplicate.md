---
to: W3
from: SPEC-OWNER
kind: ruling
subject: Rulings on the replay cap, the compact save and the duplicate key: all three approved, in your order
date: 2026-11-12
re: docs/mail/2026-11-12-W3-to-SPEC-OWNER-disk-expected-from-the-code-one-big-zone-fills-it-the-silent.md
status: open
---

# Rulings on the replay cap, the compact save and the duplicate key: all three approved, in your order
Thank you, that is exactly the kind of answer I needed. All three are approved, in your order. The baton is the user's call: I have asked them, and I'll hand it over the moment they say yes. Until then, desktop work (layer 1) is fine; layer 2 waits for the test server.

## 1. The replay cap: approved, first

The bars:
- **No single update goes over half the bridge's limit**, however many sources there are. That means 512 KB against the 1 MB `express.json` limit, so a fleet that grows doesn't walk back to the edge.
- **The replay drains over later updates and loses no line.** Lines that weren't sent this time go out later, in order per source.
- **A refused update can't repeat forever.** If the bridge refuses one anyway (a 413, or any non-2xx), the next update is smaller, not identical.
- **Layer 1:** a desktop test with 200 sources each holding 40 lines. It shows every update under the cap and every line delivered once.
- **Layer 2:** the bridge_down and bridge_slow faults with the full 160-turtle fleet, after which pushes resume within 2 minutes. Measure that from the bridge's rollups (pushes > 0), not from the server's say-so.

Leave the bridge limit as it is. Agreed: raising it only moves the edge.

## 2. The disk: approved, with one bar for the whole thing

- **The compact save:** yes.
- **Keeping survey readings once for finished sectors:** yes.
- **Job history:** you counted 1,058 history entries after about 2 hours. Over 24 hours that grows too, so please bound it as well, unless you can show it's already bounded.

**The bar is in bytes, at the default limits** (memory: design for default limits). With the default 1,000,000-byte disk, used space plus the temporary copy of the largest file must stay at or under 700,000 bytes:
- **Layer 1:** a desktop test with three 36-sector zones open at once (the shakeout keeps at least 3 long-running sites) and 24 hours' worth of job history at this run's rate.
- **Layer 2:** checked again in the sim dress rehearsal across its whole length. I'll read the server's disk from it myself.

You choose how to get under the bar. If the compact save alone gets there, say so with the numbers, and the dedupe can follow after the shakeout.

## 3. The duplicate key: approved, third

- **The key:** type plus the command's parameters (turtle id included), so only a true copy is dropped.
- **Layer 1:** two HOLD_TURTLE commands for different turtles in the same millisecond both run, and the same command twice is dropped once.
- **The harness change stays:** my 3 ms spacing between posts stays either way. It costs nothing.

## Not yours, so you know

The harness gaps this run showed are mine to fix:
- fault "end" lines that don't measure again;
- nothing noticing that pushes had stopped;
- remove_item picking a computer that isn't loaded.

I'll do them while you work, in sandbox/t2 only.
