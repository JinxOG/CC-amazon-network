---
to: SPEC-OWNER
from: W3
kind: info
subject: All W3 cards through both layers: disk card + capacity week, GPS 2 ruled and fixed, ATC pair-split fixed, warehouse inbox leak fixed; one live check needed by hand
date: 2026-11-05
status: open
---

# All W3 cards through both layers: disk card + capacity week, GPS 2 ruled and fixed, ATC pair-split fixed, warehouse inbox leak fixed; one live check needed by hand

This is the summary you asked for once the cards were done. It follows my 2026-11-04 ATC mail. Every card below has passed the simulator and the test server, with a VALIDATION block on the board. Nothing has been deployed: the user's ban stands.

## Cards now in "Done - not server validated"

| Card | What changed | Layer 1 | Layer 2 |
|---|---|---|---|
| **The server keeps its own disk tidy, and reports it** | Parts 1, 2 and 4 (db099c4, e2f8049, 171af0b; the local-limit fix in b43cd68). Part 3 is the user's config, and the study says it isn't needed. | w3_disk_retention 9/9; w3_stripped_fleet 7/7; 12 unit tests | w3-disk-tidy-b 21/21 |
| **GPS 2** (was "TODO(Completed but failed)") | **Ruling: both.** 6b08923 keeps an outage's start in gps_outage.dat, so a restart logs "still down after a server restart" instead of a second FAILED, and "back after" counts from the true start. I rewrote the Failed-if: a second FAILED inside one window is now the failure, and silence during a reported outage no longer is. | 2 unit tests fail before, pass after; w3_gps2_restart 7/7, with the old code failing 3 checks and showing the live symptom (2 FAILED for one outage, "back after 180s" for a 300 s outage) | w3-gps2-restart-b 13/13 ("back after 220s" for a 220 s outage, 80 s after the boot) |
| **TOP PRIORITY - base ATC** | As in my 11-04 mail, plus the pair-split fix below. The T2 runner places the ATC computer itself (control.spawn_computer, the atc profile's files only), so the user placed nothing. | five fault scenarios at 150 turtles | w3-atc-pair-c 14/14, with one miner and the ATC switched off while it came home |
| **The warehouse keeps every heartbeat in its inbox forever** (new) | warehouse.lua is W6's file; edited with the user's go, and W6 has been mailed. abe3e62 keeps only the 4 types tick() reads, 64 of each. | 2 unit tests fail before, pass after; the Lua heap goes 64 → 71 MB over 3 h (it was 69 → 283); 150-turtle traffic 8/8 with 37 of 37 deliveries completed | w3-warehouse-inbox-b 6/6, warehouse byte-identical to the stripped commit |

The refused-move and mutation-harness cards were done before the park, which my 11-04 mail now says correctly. The mutation card can only be closed by a person: its own text says so.

## Two fleet bugs that the capacity week found

1. **The warehouse inbox leak** (the card above). It was nearly all of a 150-turtle sim's ~70 MB per hour of memory growth, and it is what had stopped every week-long run before now. `sandbox/scenarios/w3_mem_probe.lua` lists the tables that grow, per computer, every simulated hour.
2. **A delivery pair split at the dispatch hole** (4392dcb, on the ATC card). The delivery waited 60 s for its support and then went down alone. Under the ATC that wait was too short: other traffic held the support back for 100 s. The support came out late, chased the delivery into rock it cannot dig, and was stranded in the departure tunnel. 105 deliveries were waiting by hour 105. Now:
   - under the ATC the delivery waits up to 600 s for its support;
   - its "hold" and "come home" messages name its holding slot, and a support that lagged asks for that slot.

   Proof:
   - w3_atc_pair_split, where a silent holder takes crossing J1: 3 checks fail before the fix and 8/8 pass after;
   - T2 w3-atc-pair-split-c: 10/10, with one pair.

## The capacity study

`docs/measurements/2026-11-04-server-disk-capacity-study.md`. A clean week: 168.1 simulated hours, 150 turtles, a 1,000,000-byte disk.

- **Disk:** lowest free 765,458 B and peak used 234,542 B. Nothing grows with time, because only live jobs are saved.
- **Work done:** 335 deliveries, all completed; 330 mining dispatches; 996 jobs in all; 8 restarts.
- **Faults:** no warning, no failed return, no STUCK.
- **Where 1 MB breaks:** at about 580 waiting deliveries, or about 45 mining orders, live at once. The warning comes at about half that.
- **Costs:**
  - about 19 B per turtle;
  - about 0.65 KB per waiting delivery (measured from a real backlog of 124);
  - about 4–6 KB per mining job.
- **What 10 MB buys:** backlog room, and a job history of about 45–60 days, which 1 MB cannot hold.

## A test-world finding, and the one thing that needs checking by hand

In the T2 world copy, **chunk column x 224–239 beside the arrivals hole does not tick.**

- **The probe:** w3_chunk_tick_probe placed probe computers along the base. At x 160, 200 and 220 they ran about 140 timers a minute. At x 226 (z -2786, -2795 and -2801) none started.
- **The symptom:** a delivery that stepped onto 228,67,-2801 received no events for 180 s, then booted fresh. Nothing in the game log, the bridge or the runner shows it, so it looks exactly like a fleet hang.
- **What I did:** w3_atc_pair_split now force-loads chunks 14–16, z -176..-174, and states it as an intervention.
- **The check:** someone with the live server should confirm that the live base keeps the arrivals column and the holding line (x 224–271, z -2816..-2769) loaded. I've asked the user.

## Files outside my usual set

- warehouse.lua (with the user's go).
- sandbox: core/computer.lua (each computer keeps only its newest printed lines), t2/control.py (spawn_computer writes UTF-8), plus new scenarios.

Untouched: delivery_turtle.lua, support_turtle.lua, ore_turtle.lua, and every android file.

All the W3 cards are through both layers, so I'm stopping here.
