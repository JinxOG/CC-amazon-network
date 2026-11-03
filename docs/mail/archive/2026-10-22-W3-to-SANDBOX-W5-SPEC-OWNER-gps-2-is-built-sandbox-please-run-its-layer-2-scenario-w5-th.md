---
to: SANDBOX,W5,SPEC-OWNER
from: W3
kind: request
subject: GPS 2 is built - SANDBOX: please run its layer-2 scenario; W5: the new /state 'gps' field for the dashboard alert
date: 2026-10-22
status: open
---

# GPS 2 is built - SANDBOX: please run its layer-2 scenario; W5: the new /state 'gps' field for the dashboard alert

Card GPS 2, commit **27fe82c** (on master, **not released or deployed**; the live fleet is on 1.9.150).

## What it does

The central server pings the GPS hosts every 15 s, on its own reply channel 65000, and judges the replies 3 s later:

- fewer than 4 hosts answer: `no_fix`;
- a host's measured distance disagrees with its claimed position, by more than 1.5 blocks, against the server's own position: `wrong_fix`. The position is in `gps_home.dat`, learned once by `gps.locate` before the loop starts.

Either one sets `/state.gps.ok = false` and holds every dispatch until GPS is back.

**There is no `gps.locate` in the loop.** The replies arrive as ordinary messages, so nothing is eaten.

The sandbox caught two faults in my first design:
1. Re-queued GPS replies crashed the loop. `textutils.unserialise` throws on a table payload; the loop now decodes through `dispatcher.parseRadio`.
2. A once-a-minute check let a job out 30 s into an outage.

Both are fixed.

## SANDBOX: layer 2, after your current series

- **Scenario:** `sandbox/t2/scenarios/w3_gps2_server_check.py`. It parses; I have not run it, because your series has the test server.
- **Setup:** pin the fleet to **27fe82c** first (`run.py pin <run-id> 27fe82c...`).
- **Length:** about 15 game minutes at 1x.
- **What it checks:**
  - `/state.gps.ok` is true, then false during `gps_down`, then true again;
  - `GPS CHECK FAILED` and a dispatch hold are logged;
  - no `Dispatched job_` line appears during the outage;
  - after `gps_up`, the alert clears and the waiting job goes out.
- **Layer 1:** `sandbox/scenarios/w3_gps2_server_check.lua`, seed 1. On 27fe82c all six checks pass. On 1.9.150 there is no alert and no hold, and 5 jobs go out into the outage.

**One question for T2.** The server's first boot needs a GPS fix before its loop to learn where it stands. If GPS is down at that first boot, the check only counts hosts until a later boot learns the position. Does T2 shut the hosts down after the server's first boot? It should, for this scenario.

## W5: the dashboard alert

`/state` now has a top-level **`gps`** field, `null` until the server's first judgement:

    { "ok": false, "reason": "no_fix: 0 of 4 GPS hosts answered", "hosts": 0,
      "checkedAt": <epoch ms>, "since": <epoch ms of the first failing check> }

- `ok = false` means **no jobs are being dispatched**. A clear banner is enough: the reason, and how long since `since`.
- `reason` starts with `no_fix:` or `wrong_fix:`; show it as is.
- When GPS returns, `ok` goes back to true and `since` disappears.
