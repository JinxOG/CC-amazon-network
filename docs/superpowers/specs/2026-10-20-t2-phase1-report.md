# T2 phase 1: the run tool, the fleet in real Minecraft, and speed with the fleet working

Written 2026-10-20 by the sandbox builder. Follows `2026-10-20-t2-phase0-report.md`. User's go: "Go ahead" (2026-10-20),
npm install of `express` and `rcon-client` into `G:\TurtleOS-Sandbox\testserver\bridge-deps` approved separately.

## What exists

`sandbox/t2/run.py`: `start <run-id>`, `status`, `command <run-id> <TYPE> [json]`, `stop`.
- `start` makes the run folder from the world copy (`prepare_run.py`: HTTP rules rewritten to allow only 127.0.0.1:3000 and
  raw.githubusercontent.com, deny the rest including `$private`, and checked; the start is refused if they differ), copies
  the **real `server.js` and `public/`** from this worktree into `<run>/bridge/` (the commit is recorded in
  `BRIDGE_SOURCE.txt`), runs it with node on 127.0.0.1:3000 with its logs in `<run>/bridge/logs`, then starts the Minecraft
  server and waits for "Done". Both processes are detached; `pids.json` keeps the pids.
- `stop` sets the tick rate back to 20, stops the server over RCON, and ends the bridge by its pid. Nothing else is touched.
  Checked: after `stop` neither process is alive.
- Tests (`sandbox/tests/test_t2_rules.py`, 7, in `sandbox/sim test`): the live copy's rules are refused; rewriting gives the
  safe set and keeps the rest of the file; allowing `$private`, allowing everything else, another localhost port or an extra
  allowed host are each refused; the start function checks before starting.

## First result: the fleet boots and works in real Minecraft

Run `p1-a` (world copy 2026-10-18 17:00, the fleet code as it sits on the computers' disks, bridge `server.js` from this
worktree, no code pinning yet):
- Start-up 106 s from the tool's start to "Done" (the first measurement, 29 s, was the server alone after mods were cached).
- **16 turtles registered with the local real bridge within about a minute** (miners node_179/181/182/183, delivery, support)
  and the warehouse ran (`[WH] alive`, RS probe `listItems` 11-52 ms, 495 items).
- `ORDER_MINE x1=1920 z1=-2624 x2=1984 z2=-2624 minerCount=2` through `POST /command`: `Dispatched job_0206 [MINE] ->
  node_183 (solo)`, `Assigned sector (1952,-2624) [SURVEY]` 75 s later. Same behaviour as live and as the simulator.

## First number: speed with the fleet working a real job

The tick rate was stepped (Madgique's Tickrate Changer; Citadel and Alex's Mobs parked), 15 s to settle and 60 s measured per
step, the job running (node_183 surveying):

| tickrate | game ticks per real s | speed | mean tick time | bridge log lines per game minute |
|---|---|---|---|---|
| 20 | 20.0 | 1.0x | 6.6 ms | 21.0 |
| 30 | 30.3 | 1.5x | 5.3 ms | 10.6 |
| 40 | 40.0 | **2.0x** | 4.4 ms | 7.5 |
| 60 | 62.5 | 3.1x | 7.9 ms | 5.4 |

The server held every step. **The spec's 2x bar is met with the fleet working** (tick time 4.4 ms at 2x against a 25 ms
budget); at 3.1x the tick time rose to 7.9 ms against 16 ms. I did not go past 60. A burst of 27 ms mean tick right after
boot (every computer starting at once) settled to about 6 ms within a minute.

**What changes with speed, measured:** the fleet's log output per *game* minute falls as the speed rises (21 / 10.6 / 7.5 /
5.4), roughly in proportion to 1/speed. Its reporting runs on the real clock, not the game clock (the fleet uses
`os.epoch("utc")`; CC:Tweaked timers follow ticks). So at 2x the fleet reports and checks half as often per game minute.
That is the spec's point that T2 at speed shows mechanics, not timing; the highest speed at which fleet behaviour is
unchanged is therefore below 2x for anything that depends on those real-clock intervals.

## NOT STAGED in this run (to be repeated in every run report)

- **Citadel and Alex's Mobs are left out at speed** (Madgique's mod conflicts with Citadel; Alex's Mobs needs it).
- The 13 server-only mods from the pack file are not in the test server (awesome-dungeon x3, get-it-together-drops,
  in-control, item-banning, lithostitched, mobs-properties-randomness, structure-layout-optimizer, tectonic, too-fast,
  village-spawn-point, yungs-better-mineshafts). Five client-only jars are also left out (listed in
  `server\mods-left-out\LEFT_OUT.json`).
- `radio_loss` and `radio_latency` (T1 only, spec 6.6).
- Run `p1-a` used the code already on the computers' disks; pinning is built (section above) and was proven in `p2-a`.
- No job was run to completion (a full three-sector job is about 3.9 hours at 1x), so there is no T1/T2 job-time comparison.

## Pinning through the real update path (done, run p2-a)

`run.py pin <run-id> <40-hex-commit>` sends `UPDATE_ALL` with `params.ref = <commit>` through the bridge's `/command`. That
is the production path: `central_server` restarts onto the commit (`stageFanOut` -> `proto.stageUpdateRef` -> `updater.lua`
fetching `raw.githubusercontent.com/JinxOG/CC-amazon-network/<commit>/...`, the one host the HTTP rules allow), then sends
`UPDATE_ALL{ref}` to each turtle as it goes idle. It waits until the server and every registered turtle report the commit's
`proto.VERSION`. Result on the 2026-10-18 world (fleet idle, commit 2f2515e = 1.9.149, world code 1.9.148): server restarted
onto 1.9.149 in about 10 s, UPDATE_ALL delivered to each turtle, **all 16 turtles reported 1.9.149 after 50 s**. Checked on
disk: `protocol.lua` and `turtle_base.lua` on computers 96, 143, 181 and 183 are byte-identical to `git show 2f2515e:<file>`.
The commit must already be on GitHub, and the fleet should be idle (a busy turtle updates when it next reports idle).
Tests added: the version is read from the commit; a ref that is not a full commit id is refused (9 tests in all).

## Next (phase 2 and the rest of phase 1)

The control verbs one by one (6.6), scenario
files and a report like T1's, and one T1-versus-T2 comparison of the same three-sector job at 2x.
