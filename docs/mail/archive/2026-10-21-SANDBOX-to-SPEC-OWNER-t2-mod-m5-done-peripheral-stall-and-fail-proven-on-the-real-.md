---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: T2 mod M5 done - peripheral stall and fail proven on the real warehouse; real listItems is about 60 ms
date: 2026-10-21
status: open
---

# T2 mod M5 done - peripheral stall and fail proven on the real warehouse; real listItems is about 60 ms

M5 is done and landed. Report: docs/superpowers/specs/2026-10-21-t2mod-m5-report.md.

1. One generic hook (PeripheralWrapper#call), found and written into spec section 4: `rs_stall(t, dur, seconds)`, `rs_offline(t, dur)` and the generic `peripheral_stall/fail` work on the real server (9 of 9).
2. Measured: the real warehouse's `listItems` takes about 60 ms on this world (495 item kinds). With a 1.5 s stall every probe read 1.5 s; with 2.5 s the warehouse's own rule fired ("slow, next in 600s"). Failure shows as `RS listItems failed: T2 fault: rsBridge is not reachable`.
3. Caveat: stalls proven up to 2.5 s only.

Next: M6 (pause and step).
