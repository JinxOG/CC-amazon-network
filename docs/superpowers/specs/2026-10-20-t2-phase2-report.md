# T2 phase 2: control verbs, each proven against a live test-server run

Written 2026-10-20 by the sandbox builder. Code: `sandbox/t2/control.py` (the verbs), `sandbox/t2/prove_verbs.py` (the proofs;
`python sandbox/t2/prove_verbs.py <run-id> [verb ...]` against a started run, writes `<run>/VERBS.json`), `sandbox/t2/run.py`
(`launch`/`relaunch`: restart the server on the same run folder). Run `v-a`, world copy 2026-10-18, fleet idle then working.

| Verb (T1 name) | T2 means | Result | What was seen |
|---|---|---|---|
| computers | `/computercraft dump` | **proved** | 31 computers listed with on/off and position |
| read any computer's disk | plain file read under `world/computercraft/computer/<id>/` | **proved** | 127 KB of #181's startup.lua; computer still on |
| `set_fuel` | `/data modify block x y z Fuel` | **proved** | NBT reads the new level and the fleet's own heartbeat reports it to the bridge, no reboot |
| `set_slot` / `clear_slot` | `/data modify block ... Items` (clearing overwrites with an empty stack: `data remove` does not empty a slot) | **proved at the NBT level** | stack set and cleared in the block entity; that the turtle's Lua sees it is not separately checked |
| `shutdown` / `turn_on` | `/computercraft shutdown #id` / `turn-on #id` | **proved** | #143 off (dump N) then on (dump Y) |
| `gps_down` / `gps_up` | the same, on the computers whose disk runs `gps host` (found from the disks: 48, 49, 50, 51) | **proved** | all four off, then all four on |
| `tps_drop` / `server_lag` | Madgique's `/tickrate N` for a while, then 20 | **proved** | 5.00 game ticks per real second for 30 s |
| `server_crash` | kill the process (no save); `restart_after_crash` starts it on the same folder | **proved** | 31 computers back, turtles back online; the bridge kept running |
| `world_restart` | clean `stop` and a start on the same folder | **proved** (inside the save-point proof) | |
| `snapshot` / `restore` | `save-all flush` and a copy of the world folder; restore stops the server, swaps the copy in, starts again | **proved** | #182 fuel 1234 saved, set to 999, restored: 1234 again after the restart |
| `teleport` | `/clone <turtle block> to <dest> replace move` | **proved, a finding** | #141 moved 6 blocks: dump shows the new position, computer stays on, **no restart** (no new INIT lines); the turtle then acts on its stale idea of where it is until it asks GPS. This is the reboot-free move the planned test mod (6.10) was to supply: /clone already gives it |
| `spawn_turtle` | `setblock computercraft:turtle_advanced[...]{LeftUpgrade:modem,Fuel:n}` gives it an id (off, no disk); the code files of a donor computer of the same role are copied into its disk folder; `turn-on` | **proved** | #204 spawned with SUPPORT code; `node_204` registered with the real bridge as SUPPORT, assigned a dock |
| radio listener | an advanced computer (`setblock ...{On:1b}` is what gives it an id) with a wireless modem on top (`facing=down`), running `sandbox/t2/lua/radio_log.lua`; segments are harvested from its disk to `<run>/radio/<id>/` | **proved** | heard the fleet's HEARTBEAT and HEARTBEAT_ACK traffic (about 360 messages a minute on channels 1 and 1000+id), each line with UTC time, game seconds, channel, reply channel, distance and the text |
| `radio_loss`, `radio_latency` | none | **raise `Unsupported`** | T1 only (6.6) |
| `chunk_unload` | none | **raises `Unsupported`**, with the reason | this world's chunks are held by the chunk-loader turtles' Advanced Peripherals tickets (`advancedperipherals_ForcedChunks.dat`); FTB Chunks has no claim on the base; `ftbchunks admin unload_everything` changed nothing on the 31 loaded computers. Needs the test mod (6.10) |

Not done in this phase: T1-style scenario files and a report (phase 3), a T1-vs-T2 job comparison.
Caveats: every proof was on the client-set mod list with Citadel and Alex's Mobs parked and the 13 server-only mods missing
(NOT STAGED, as in every T2 run report). `set_slot` is NBT-level. After `teleport` the turtle's behaviour on its stale position
is real fleet behaviour, not a verb defect, but it means a position test needs the turtle to GPS again.
