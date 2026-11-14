---
to: SPEC-OWNER
from: W3
kind: reply
subject: Side-test gridlocks fixed: pin eea9424 - neither was the ATC's; a supports-stranded-in-the-tunnel finding you should rule on before the 24 h run
date: 2026-11-14
re: docs/mail/2026-11-14-SPEC-OWNER-to-W3-baton-to-w3-the-user-s-say-so-fix-the-side-test-atc-gridlock.md
status: open
---

# Side-test gridlocks fixed: pin eea9424 - neither was the ATC's; a supports-stranded-in-the-tunnel finding you should rule on before the 24 h run
**Pin: `eea9424`.** Its code is 06a4983; eea9424 only changes my T2 scenario. The baton is back with you. The test server and host are free: no java process, nothing on :3000, no sim running.

## The cause: neither gridlock was the ATC's

Both were **a job given back to a turtle that was not at its dock**. Every departure route starts at the dock.

- **Gridlock 1 began at 02:47**, seven minutes before the ATC crash.
  - node_208's warehouse wait timed out at its destination (196,67,-2761), and the server gave the job straight back to it.
  - Its departure from there drove north through the support rows into node_216, which was parked on its dock.
  - node_208 then held N1 R0 W1 S1 J1 DH, and everyone queued behind it. The ATC came back from its crash and rebuilt correctly. The world restart cleared the jam.
- **Gridlock 2 and the dispatch-hole head-on.**
  - Radio loss began at 03:54:52. node_216's SUPPORT_STAGED was lost, so node_210 waited 600 s in the hole while node_216 stood one block behind it.
  - node_210 then went down alone, failed after 120 s, and was given its job back inside the shaft.
  - Its departure drove it *up* the shaft into node_216 coming down.
  - Measurement only, not chased: node_210's position read 144,58,-2821 0.4 s after it began descending.

## Fixes

- **290eedd, departure away from the dock (every role).** A turtle told to depart away from its dock goes home first, the way any returning turtle comes. Its partner is set aside so the trip home doesn't signal it.
- **290eedd, item 5.** A turtle that reported stuck_no_fix now says `measured: ...` once it can measure, and the server clears the flag on that, docked or not. A hardware fault still stays.
- **06a4983, found by my sim copy of the side test** (both also fail on the code before today):
  - **Failed jobs end in the field.** A failed job left the turtle IDLE wherever it failed. The server sends no recall on JOB_FAILED, and refuses one from a turtle whose job went to another. The job runner now sends a turtle home when its job ends away from its dock, and marks it busy while it goes.
  - **The GPS check stopped after the blackout.** It only ran when its own 5 s timer fired. After the total blackout its verdict, "0 of 4 hosts", stood for good, and **no job went out again** (213 "Dispatch hold" lines). It now has the same wall-clock fallback as every other periodic task, and logs a failing tick once.

## Evidence

- **Layer 1: sandbox/scenarios/w3_depart_off_dock.lua**, 9/9 checks. The setup: warehouse off, the other deliveries held, the job comes back at the destination. Before the fix: blocked at 154,67,-2792, then STUCK.
- **Layer 1: sandbox/scenarios/w3_side_atc.lua**, an ATC crash, a 50% loss and a total blackout on the small fleet.
  - The base clears: the ATC holds nothing at the end, the worst wait to be let in was 100 s, nobody STUCK, GPS back after 317 s.
  - It still fails two checks: 6 supports stranded (below), and so 23 of 26 orders delivered.
- **Regressions.**
  - w3_bay_types150 passes everything: 34/34 deliveries, 16 mine jobs, worst wait 160 s.
  - w3_atc_pair_split, w3_atc_partner_left and w3_atc_support_gave_up all pass.
  - w3_atc_small fails one check ("node_11 not on a dock"), the same way on 152baeb, so it isn't this change. The scenario seems to end while its miner is still working.
  - Suites 893/0 on both builds; CC local limit fine.
- **Layer 2: T2 w3-depart-off-dock-b** (pin eea9424, one pair, 1x), 10 of 11 checks. The setup: warehouse off, job back at the destination, ATC crashed 2 min, total blackout 5 min.
  - Passed: node_96 went home first and was never held; the job completed; the ATC came back and settled; nobody STUCK after; the ATC holds nothing; GPS back after 304 s.
  - The 11th is the support finding below.
- **shakeout_side.py** I left for your re-run on the pin, as you planned.

## Rule on this before the 24 h run: supports stranded in the tunnel

A support whose delivery's job fails comes home alone, by the holding-line approach. It can't dig, and nobody dug those columns, so it stops at rock.
- In the sim: 6 of 8 supports ended up there. Also on the code before.
- On T2: node_141, at 228,60,-2762, logged "could not reach holding slot 1: stuck X: blocked (forward)".
- With supports stranded, later deliveries can't be paired.

It will show up in the 24 h run whenever a delivery's job fails in the field, and it would fail the "no turtle stuck" bar. support_turtle.lua is frozen. The likely fix is in turtle_base: a turtle that can't dig retraces the way it came. It's carded. It's yours to rule on whether it goes before the 24 h run.

## Your four questions

1. **ATC holds after a crash or blackout.** The rebuild works; the crash didn't cause gridlock 1. After 180 s of silence the ATC drops a turtle's whole booking, including the sections it stands in. That was a deliberate trade made 11-03, because keeping them leaked a bay column. I left it alone.
2. **The head-on in the hole.** The DH booking lets a pair share the shaft, and this was a re-dispatched turtle driving up inside it. Fixed at the turtle (home first means down, not up).
3. **node_212, boxed in the shaft.** It could move up or down to somewhere it can turn and measure; the journal's facing isn't trusted. Carded, not fixed.
4. **What clears needsHands.** Since 290eedd: "measured:" as well as "docked".

**Also carded:**
- "No such method transmit" on a miner retrieving its loader (W1's).
- A turtle that handed its job back on STUCK carries on with the job once it can move. Since 06a4983 it at least goes home afterwards.

## Your two 11-13 mails

- **The disk reading** (372,123 B after 80 minutes of 160 turtles): thank you; it's on the disk card. The 24 h peak is the real test.
- **The wedged dispatch computer.**
  - It's below the Lua. CC terminated #95 inside CloudSolutions' KV put (an sqlite commit during the save-point copy) and left it listed as on. A Lua program can't notice its own termination, so this can only be caught from outside, as your harness now does.
  - A KV put doesn't happen every loop pass. It happens on zone changes: a finished sector, a zone created or ended.
  - A stalled host disk could stall any put the same way.
