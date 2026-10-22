# Community turtle programs: what to adopt (text copy)

Text extracted from the user's PDF report (2026-10-17, @Gladious) so engineers can read it in the repo. Tables lost their layout in extraction; the spec owner's assessment and the board cards are in `docs/mail/2026-10-22-SPEC-OWNER-*community*`.

```text
Community Turtle Programs: What to Adopt
Oct 17, 2026  ·  @Gladious
Summary
No community program is worth installing as-is, but nine ideas from them are worth
building into our own code. Two forum programs were reviewed in depth (GeoMiner and
Kepler's Schematic Builder), plus six more community repos and the GPS and recovery
advice on the CC forums.
Our fleet already does more than any of them: server-issued sector leases, recall, refusing
to dig a turtle, GPS-checked positions, saved state on boot, and an autonomous return
home when the server is down. The gaps they expose are GPS outages, which parked all
15 turtles on 2026-09-17, and the builder, which does not exist yet.
Recommended order:
1. Add GPS hosts and chunk-load them (in-world setup, no code).
2. Have the central server check GPS itself and alert the dashboard.
3. Fuel-based position recovery and saved facing, as one release of the movement core.
4. Builder work, once Probe C resolves: no-dig navigation, then route planning on the
bridge.
5. Mine ore from the adjacent block (small, optional).
Programs reviewed
None of these can be dropped into our fleet: each assumes one turtle run by hand from its
own screen, with no server, leases or recovery. Source code was read for each program;
the mod was checked from its project page.
<!-- page 1 of 7

Program What it does Verdict What we take
GeoMiner (MHDtA-dev,
Apache 2.0)
Geo-scanner miner
with optional A*
through air; Basalt
GUI
Weaker than our
miner: never checks
if a move
succeeded, no fuel
or inventory
handling, digs
anything including
turtles, no
networking
Mine ore from the
adjacent block
Schematic Builder
(Kepler, MIT, last
updated 2022)
Builds from a
schematic, restocks
from a chest,
resumes from a
progress file
Can't be used:
reads only pre-1.13
MCEdit
.schematic files
and needs the
whole Opus OS
Wrench and
piston block
facing; bottom-up
build order;
pathfind without
digging near the
site
smart-turtle
(luochen1990, 2020)
High-level turtle
library with obstacle
avoidance
A library, not a
program
Wall-following
navigation for the
builder
cc_builder
(johnmiddleton12, 2023)
Python pipeline:
.nbt to JSON to a
per-layer route,
emitted as Lua
No block facing;
generated files
reach ~864 KB
Plan routes off-
turtle, on the
bridge
SWARM (ninnghazad,
stalled since 2014)
Job server plus a
shared map server
for many turtles
Job server is a
simpler version of
our leases
A shared map of
solid blocks at the
build site
mine (alexperovich,
2022)
Area, branch and
sphere mining with
vein-following
Our geo scanner
already sees whole
veins
Nothing now;
maybe patterns
for a future
EXCAVATE job
CC-VeinMiner
(BrainStone, 2023)
Mines whole veins
by checking
neighbouring blocks
Superseded by our
scanner
Nothing
<!-- page 2 of 7

Recovery after a server or GPS outage
GPS is our single biggest point of failure, and four changes would turn a full stop into a
short pause. On 2026-09-17 all four GPS hosts went silent at 00:48. All 15 turtles parked
within 30 seconds, and mining stayed stopped until someone went into the world
( docs/mail/2026-09-17-W3-to-SPEC-OWNER-stopped-all-four-gps-hosts-went-
silent-at-00-48-fleet-parked.md). Nothing was lost, because a turtle without a fix
refuses to move.
Already handled, so not in scope: resuming from saved state on boot, autonomous return
when the server is down, recovery of placed scanners and loaders, and not counting a
GPS refusal as a sector failure ( central_server.lua:2357).
1. More GPS hosts, chunk-loaded
gps.locate() needs answers from at least 4 hosts that do not all lie on one plane. We
run exactly 4 ( gps_host.lua), so losing any one stops the fleet.
Add 2–4 more. Any computer that never moves can also run gps host with an ender
modem: the central server, the warehouse, dock computers.
Chunk-load every host. The 09-17 report's top suspects were the hosts' chunk
unloading or the hosts not restarting after a world reload. The CC:Tweaked GPS guide
calls out chunk loading for this reason.
Cost: in-world setup only, no code.
2. Server-side GPS health check
Today the first sign of a GPS outage is turtles failing.
The central server sits at a fixed, known position. Have it call gps.locate() about
once a minute and compare the answer with where it knows it is.
On failure or a wrong answer: show an alert on the dashboard and hold new dispatches
until GPS is back.
Program What it does Verdict What we take
CCChunkloader (mod) Turtle chunk
loading; keeps state
and wakes turtles
after a restart
Fabric 1.20.1–1.20.6
only; our pack runs
Forge
Nothing unless
the pack changes
<!-- page 3 of 7

Cost: a few lines in central_server.lua plus a dashboard field.
3. Position recovery from the fuel level
Forum advice is to save position after each move, but a crash between the move and
the save leaves the record one block wrong (FTB forum).
Fix: before each move, save the position, facing, fuel level and the intended move.
Every move costs exactly 1 fuel, so after a reboot a fuel level 1 lower means the move
happened, and an unchanged one means it didn't.
New rule: a turtle with a recent good fix may keep navigating on this saved position for
a bounded number of moves, enough to get home. When GPS returns it checks the two
agree, and parks if they don't.
Result: a GPS outage becomes "the fleet finishes its trip home and waits", not "the
fleet parks in the field".
Limit: it fails on a server with unlimited fuel. Ours uses fuel.
Cost: changes the movement core in turtle_base.lua; needs careful tests.
4. Facing recovery
Turning costs no fuel, so facing can't be checked the same way. Save the facing before
every turn as part of #3.
If facing is still unknown and GPS is up, take a fix, move one block, take a second fix,
and work out the direction from the difference.
Ship together with #3.
Builder
The builder should be our own code, built to the integration spec, with four ideas taken
from these programs. All of it waits on Probe C, the spec's top open item, which checks
which block states (stairs, slabs, facing) a turtle can actually place
( docs/superpowers/specs/2026-08-18-system-integration-design.md, §16 and §17).
5. Navigate without digging
Our base.move.to digs through whatever is in the way, so a builder using it would
break its own work.
smart-turtle's move.to heads straight for the target until blocked, then follows the
wall on a chosen side until it is closer, and repeats.
<!-- page 4 of 7

That gets around placed blocks with no full map and no A*. It is cheaper than
GeoMiner's A*, which checks every open position on each step and pauses 0.05 s per
position it checks.
Kepler's builder does the same in two stages: straight lines to the site, then pathfinding
with digging turned off for the last stretch.
Keep the turtle inside the build site's bounding box, which the spec already computes
at parse time (§11.6).
6. Plan routes on the bridge
cc_builder does the heavy work offline in Python: it searches each layer for the
shortest route within a fuel budget, then writes out Lua.
Do the same in the Node bridge, which already owns blueprint conversion (W5). Send
each column with its route and fuel cost, so the turtle only follows instructions.
cc_builder's generated file reached ~864 KB, close to the 1,000,000-byte computer
storage limit we measured (V8). That confirms the spec's plan to send columns over
the network and never store a whole build on the turtle.
7. Set block facing with a wrench and piston
Plain turtle.place() can't choose which way stairs, logs and similar blocks face.
Kepler's builder places the block, then turns it with a wrench, or pushes it into place
with a piston ( builder/apis/turtle.lua, lines 723–810). A placement planner picks
which side to place each block against ( builder/apis/schematic.lua, lines 488–700).
Use this as the fallback if Turtlematic's use() fails Probe C, and as a candidate method
when designing the probe.
Open question: which wrench mods are in our pack, and can their wrench turn blocks
when a turtle uses it?
None of the other builders found handle block facing at all; cc_builder lists it as
missing.
8. A shared map of the build site
SWARM runs a map server holding the explored blocks for all turtles to path through.
For us, the server already knows the placement set and which columns are done. It can
send each builder a list of the solid blocks around its column, so #5 works from known
walls, not by bumping into them.
<!-- page 5 of 7

SWARM's author notes no single pathfinder suits both mazes and open ground, which
is another vote for #5 over full A*.
Mining
9. Mine ore from the adjacent block
Our navToOre ( ore_turtle.lua:1279) moves the turtle into each ore's spot, digging
the ore as it enters.
GeoMiner instead stops in the free space next to the ore and digs it from there. That
saves about one move, and so one fuel, per ore.
Small and optional: measure it on one job before deciding.
Considered and rejected
Idea Seen in Why not
A* pathfinding through air for
mining
GeoMiner Underground is almost all
solid, so A* finds long cave
detours or no path, and skips
the ore. Digging straight is
faster and cheaper.
Vein-following by checking the
six neighbouring blocks
mine, CC-VeinMiner Our geo scanner already sees
the whole vein.
Porting a builder's code Schematic Builder,
cc_builder
Pre-1.13 file format, Opus OS
dependency, single turtle run
by hand. Almost nothing
would survive the port.
Their swarm and job-server
designs
SWARM, smart-turtle, a
forum "swarm miner"
Simpler versions of our
sector leases. The forum
design's turtles mined each
other, which digGuarded
already prevents.
CCChunkloader mod Modrinth Fabric-only; our pack is Forge.
<!-- page 6 of 7

Sources
GeoMiner forum post and source
Schematic Builder forum post, wiki and source
luochen1990/smart-turtle
johnmiddleton12/cc_builder
ninnghazad/SWARM
alexperovich/mine
BrainStone/CC-VeinMiner
CCChunkloader on Modrinth
CC:Tweaked: Setting up GPS and gps module
FTB forum: resuming mining turtles after logging back in
FTB forum: a turtle program that survives server resets
Internal: docs/superpowers/specs/2026-08-18-system-integration-design.md; the
2026-09-17 GPS outage report in docs/mail/
Idea Seen in Why not
Fixed mining patterns (branch,
sphere, cube)
mine, built-in excavate Not needed now; revisit for
the planned EXCAVATE job.
<!-- page 7 of 7
```
