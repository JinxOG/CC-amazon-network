# T2 phase 0: can the local test server be built, and how fast can it go

Written 2026-10-20 by the sandbox builder. Spec: `2026-10-20-testing-procedures-design.md` section 6 and section 9 phase 0.
Everything below was measured on this PC (Ryzen 7 5800X3D, 32 GB). The user's Modrinth instance was only read.

## What was built

- `G:\TurtleOS-Sandbox\testserver\server\`: Forge 1.20.1-47.4.20 dedicated server (official installer, sha1 checked,
  run with the Java 17 the Modrinth app already has), plus the instance's mods, config, defaultconfigs and kubejs copied
  in. The world is the 2026-10-18 17:00 backup, copied into a disposable run folder (`runs\<id>\`).
- `sandbox/t2/`: `prepare_run.py` (run folder from a world copy, EULA, server.properties, local RCON, and the ComputerCraft
  HTTP rules rewritten to allow only 127.0.0.1:3000 and raw.githubusercontent.com and deny everything else including
  `$private`; `rules_are_safe` refuses a run whose rules differ), `rcon.py`, `phase0.py`, `trim_client_mods.py`.

## Measured

| | |
|---|---|
| Start-up to "Done" | 29.3 s after the JVM starts (mod loading about 1 min before that: 222 mods) |
| First ticks | "Can't keep up, 2491 ms or 49 ticks behind" once, right after start |
| Tick time, nobody logged in, base and fleet chunks loaded | overworld mean 3.4-4.8 ms over 8 samples, overall 3.6-4.9 ms (end and nether 0.01 ms). TPS 20.0 |
| Ceiling at the tick time | 50 ms / ~4 ms = **about 12x** real time (10x at the worst sample). Ticks alone; not tested with a tick-rate mod |
| Memory | working set 7.4 GB with -Xms2G -Xmx6G (JVM, mods, world) |
| Entities loaded | 159 (38 zombies, 26 super glue, 25 falling blocks, 16 endermen, ...) |
| RCON `forge tps` | answers instantly when the server is idle, but timed out (10 s) once while the first ticks were still catching up |

## Client-only mods that had to be left out of `server\`

Five of the instance's 227 jars refuse to load on a dedicated server: oculus, EasierSleeping, NoFog, LegendaryTooltips,
EquipmentCompare (the last one was swept up with LegendaryTooltips, which it bundles; it is a client mod anyway). They are
parked in `server\mods-left-out\` with the reason in `LEFT_OUT.json`.

## NOT the same as the live server's mod set

The instance's own `packwiz.json` marks 13 mods as *server-only*, so they are **not in the client instance** and not in
this test server: awesome-dungeon (and -nether, -the-end), get-it-together-drops, in-control, item-banning, lithostitched,
mobs-properties-randomness, structure-layout-optimizer, tectonic, too-fast, village-spawn-point, yungs-better-mineshafts.
The user chose (2026-10-20) to leave them out for now. The world is already generated, so worldgen mods matter little;
in-control (spawns), too-fast and item-banning can change behaviour and are worth fetching before a run is relied on
(the pack URL is in the instance's `sync.bat`; fetching needs the user's OK). Read: this test server's drops and
mechanics are the client set's until then.

## Real-clock use in the fleet (spec 6.8)

Counts of `os.epoch`/`os.clock`/`os.time` in the fleet files: central_server 91, turtle_base 23, ore_turtle 17, warehouse 10,
protocol 3, updater 0. The fleet mostly uses `os.epoch("utc")`, which is real UTC. CC:Tweaked 1.120.2's timers (`os.startTimer`, `sleep`) follow
server ticks: the jar's `Environment` class keeps `timers` with a `ticksLeft` count that `tick()` decrements, while
`OSAPI.epoch` reads the real clock. So at N x tick rate the game runs N times more per real second: a turtle's timers
fire N times as often per real second, but a deadline written as "30 real seconds" spans 30 x N game-seconds. Deadlines
therefore get N times LONGER in game time (more lenient), not shorter; the first version of this paragraph said the
opposite and was wrong (the Head Engineer's check, 2026-10-20, confirmed against the jar). Consequence for the spec:
T2 at speed proves mechanics, not timeout behaviour (a turtle that live is declared lost at 30 s is not until 30 x N
game-seconds in T2, so a timeout bug can hide); timeout behaviour stays with T1, or with T2 at 1x. The highest speed at
which fleet behaviour is unchanged has not been measured yet; it needs a tick-rate mod (the user's OK is needed) and a
T1-vs-T2 comparison at 1x, 2x and 4x.

## Not done / not verified in phase 0

- Whether the fleet computers actually booted and ran: there was no bridge on 127.0.0.1:3000 and nobody logged in; phase 1
  runs the real `server.js`.
- Any tick-rate mod (Madgique's Tickrate Changer, OverClocked: Clockworks, Tick Changer). Not downloaded.
- Memory and tick time with the fleet working a job.

## Where this leaves the go/no-go (the user's call)

The bar in the spec is about 2x. Ticks alone allow about 12x, so 2x is not ruled out by tick time; what decides it is a
tick-rate mod that works on this modpack and whether the fleet's behaviour holds at 2x. Both need the next step.
