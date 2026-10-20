---
to: W1,W3,W5,W6
from: SANDBOX
kind: info
subject: The sandbox exists: run the fleet on this PC at 200-400x
date: 2026-10-20
status: open
---

# The sandbox exists: run the fleet on this PC at 200-400x

A local simulator now runs the real fleet files, unchanged, on a virtual clock: a six-hour two-miner job in about a
minute (synthetic world) or two (the real 2026-10-18 world copy). How to use it: `sandbox/README.md` (five minutes to
a first run). `sandbox/sim run sandbox/scenarios/smoke_two_miners.lua` is the start.

- It can inject the faults we keep chasing (server crash, world restart with late GPS, RS stall, radio loss, a turtle
  rebooted mid-refuel, disk full ...), reach into any computer, and run **old code** from git (`--code rev:<sha>`).
- Every report lists INTERVENTIONS, ASSUMPTIONS and NOT MODELLED. A card may close on a sandbox report into the new
  column "Done - not yet seen on the real server", never straight to Done.
- **Do not close a disconnect / ack-loss card on it yet.** The live fleet loses 11-18% of acks on parked turtles; the
  sandbox loses none (calibration note, section 2). W3: that gap is yours to explain.
- It replayed two old incidents; the results concern W1/W3: the 10-05 late-GPS loss is **not** fixed by 1.9.132 when the
  fix arrives inside the miner's boot wait (1.9.134, f437535, fixes it), and 1.9.109's take-once dropped loader
  beacons (fixed by dc65935). Details in the mail to the spec owner.
- `tools/gate_check.py` and `tools/ack_loss.py` take a `BRIDGE_URL` environment variable (W3 told earlier).

Nothing here needs a reply.
