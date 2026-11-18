---
to: W3
from: SPEC-OWNER
kind: ruling
subject: 24 h run b stopped (the user): the server is deaf building the bridge payload at 160 turtles - build it never-deaf (b) then send only changes (a); T2 and baton yours
date: 2026-11-17
status: open
---

# 24 h run b stopped (the user): the server is deaf building the bridge payload at 160 turtles - build it never-deaf (b) then send only changes (a); T2 and baton yours
**The user stopped shakeout-24h-b at about 2.9 h (05:35 UTC, 2026-11-18).** I stopped it scenario process first, then by verified PIDs. Nothing is left running, and T2 is free. **The baton is yours.** Run report: `G:\TurtleOS-Sandbox\testserver\runs\shakeout-24h-b`.

## The blocker (your measurements, confirmed)

- buildBridgePayload takes pushBuildMs 2307 ms at 150 turtles, inside the loop, and is timed as "bridgePush". The 1,033,078-byte payload is 89% turtleLogs (579 KB) and mineZones (341 KB), rebuilt and re-serialised in full on every push.
- The server's own log: 1362 LOOP STALLs in about 3 h, median 1983 ms, p90 5335 ms, max 15890 ms. The server was deaf 22-58% of every 10 minutes. Side-h at 20 turtles: 5 stalls in 3 h.

## Ruling: both, (b) first

1. **(b) The payload is built as a coroutine the main loop steps,** one slice at a time, with no pullEvent inside the builder. This is the by-design guarantee the user's rule asks for: the deaf window is one slice, whatever the fleet size. Prove it in the sim at 150+ turtles: the worst loop stall, and that no modem_message is lost while it builds.
2. **(a) Send only what changed:** new log lines since the last acknowledged push, zones whose version changed, and turtle scalars as now.
   - The bridge side (server.js) is W5's, and W5 is offline. You may make the minimal server.js change the merge needs. Keep it to the merge, add tests in W5's style, and copy the mail to W5. My memory has server.js applying each field under `if (field)`, so a field you leave out is kept; check whether per-zone and append-only merges need more.
3. **Proof on T2 before the 24 h restart:** the full 160-turtle fleet (shakeout setup) for about 1 h with faults, reporting the LOOP STALL count, the worst stall and the "Server unreachable" rate against 24h-b's (above).

## Also in the next pin

- Your ledger-order fix, 5cd6db2 (delivery_ec unknown_kind).
- **Dock kept on disk** (node_481 and node_178: a reboot with no server means no dock, "No dock assigned, staying put" returns true, and it calls the ARR column home). Fix it if it's small; card it if not.

## For the outage card, not this pin: miners recalled

Of 70 MINE dispatches in 24h-b, 23 jobs went back:
- turtle_absent 10 (the 5-min absent rule, mostly turtles rebooting after restart_burst5 or world_restart, or unreachable on a deaf server);
- boot_recovery 5, reboot_recovery 2;
- sector_setup_failed 3;
- one each of idle_stuck_after_crash, departure_failed, server_unreachable_autonomous_return.

The user noticed "a lot of miners recalling ... an inefficient amount". With the deafness gone most of turtle_absent should go too. Report the count in the 160-turtle proof run.

## Harness (mine)

The fleet counted 161 turtles judged and 133 miners, against 128 placed: world strays survived fleet.retire_strays (node_178 at 839,200,-2813). I'll look at that.
