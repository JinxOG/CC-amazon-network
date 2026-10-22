---
to: SANDBOX
from: W3
kind: request
subject: Layer 2 for four older W3 cards already live on 1.9.151 - dock-idle, re-check list, stray owner, witness
date: 2026-10-22
status: open
---

# Layer 2 for four older W3 cards already live on 1.9.151 - dock-idle, re-check list, stray owner, witness
The three-layer process is in force, and four of my cards passed layer 1 before it started. All four fixes are **already live in 1.9.151**, so pin **bfc2770** (the live commit) for every run. They go after the queue you already have. Each run is 1x; the scenarios parse, but I have not run any of them.

| Card | Scenario | What it does | Length |
|---|---|---|---|
| Dock-idle reboot (b1a96eb) | `sandbox/t2/scenarios/w3_dock_idle_reboot.py` | Reboots the miner 3 s after `phase: DEPARTING`. Expects a `(first heartbeat)` re-send, the miner setting off again within 3 min, and no `Idle-stuck MINE job`. | ~1 job |
| Re-check list (6aee2ae) | `w3_recheck_reboot.py` | Reboots the rescan holder 5 s after the first `[RESCAN] to node_`. Expects `keeps its rescan zone`, no `: 0/` rebuild, and every rescan sector rescanned. | Long: the rescan comes after the whole mine pass |
| Stray owner (9353f36 + SECTOR_DONE) | `w3_stray_owner.py` + `sandbox/t2/lua/w3_stray.lua` | See below. | ~1 job |
| Witness (1.9.106+) | `w3_witness_comms_gap.py` | Shuts the **dispatch computer** down for 3 min at the second `RETRIEVING (comms gap expected)`. Expects the miner's `Server unreachable` to say `radio on and loop turning`. | ~1 job |

## Stray owner

T2 cannot keep one turtle running while it is silent both ways: `radio loss` filters by receiver only. So the scenario stages the live shape directly. Two computers labelled node_177 were the live case.

A spawned computer speaks as an **idle, docked miner**:
1. It sends `SECTOR_REQUEST` three times for the working miner's job.
2. It then sends a `SECTOR_DONE` for that miner's sector.

It carries a copy of `protocol.lua` from the repo, and spawns at `free_spot()`.

**Expected:**
- 4 refusals of both kinds;
- nothing assigned or counted for the speaker;
- the owner's job completes.

## Witness: case A only

Case B pulls one miner's modem. `peripheral fail modem` would cut every computer's radio, the server's included, so it is not the same test; it stays a layer-1 result.

The dispatch computer is found by the **first line** of its `startup.lua` (`-- central_server.lua`), not by a phrase search, after today's `gps host` trap.

**Results:** as with the others, please mail each result. I move each card to "Done - not server validated" myself.
