# Android feasibility — the chunk-loading question

Status: **feasibility study, pre-spec.** No implementation decision is final until
the system spec lands and the four probes in §7 have been run.

## 1. The question and the short answer

The building system was designed around CC Androids because `useBlock` is a real
player right-click, which gets block orientation right for free. The objection
raised against them is that **Androids cannot chunk-load themselves**.

**The objection is correct, and it is not a configuration problem — it is a mod
boundary.** But it is also **much less damaging to building than the equivalent
problem is to mining**, because a build site is static and its footprint is known
in advance. Androids remain viable. What they are not is self-sufficient.

Verdict: **conditionally feasible, pending probes A–D.** The recommended shape is
a hybrid (§8), not a straight Android-or-turtle choice.

## 2. Verified environment facts

Carried over from [chunkloader-footprint.md](chunkloader-footprint.md), verified
in-world 2026-08-13. These are measured, not assumed.

| Fact | Value |
|---|---|
| Chunk loading mechanism | Advanced Peripherals **Chunky Turtle** |
| Registry name | `advancedperipherals:chunk_controller` |
| `chunkyTurtleRadius` | 2 → **5×5 chunks = 80×80 blocks**, grid-aligned |
| Loader turtle item | `computercraft:turtle_advanced` |
| Idle placed loader holds chunks? | **Yes** — measured 20.8 min, no stall |
| `chunkLoadValidTime = 600` decays idle loaders? | **No** — measured, does not |
| Upgrade survives place → break → re-place? | **Yes** |
| Chunky works on a *moving* turtle? | **Yes** — `equipment.lua` "travel" mode |

The last two rows matter more than they look. A placed loader needs **no running
program** to hold its chunks, and a chunky upgrade works while equipped on a
turtle in motion. Both are load-bearing for §4 and §5.

## 3. Why an Android cannot self-load

Two independent reasons, either one sufficient:

**The upgrade is a turtle upgrade.** `advancedperipherals:chunk_controller` is
Advanced Peripherals' *Chunky Turtle*. Androids have no turtle upgrade slots.
There is no API surface for it either — the full function list at
<https://github.com/ThunderBear2006/CC-Androids/wiki/The-API> covers movement,
inventory, fuel, containers, and sensing, with **no chunk-loading function of any
kind**.

**Even the optimistic case is not free.** If it turned out that
`chunk_controller` is also registered as a *pocket* upgrade (probe A), it would
compete with the ender modem for the Android's pocket upgrade slot. An Android
holding a chunky and no modem is chunk-loaded and **deaf** — it cannot register,
heartbeat, or receive a job. That is the exact tradeoff `equipment.lua` exists to
manage for miners (modem+chunky vs modem+pickaxe), except an Android has no
`equipSlot` equivalent for upgrades, so it could not swap mid-job the way a miner
does.

Treat self-loading as unavailable. Design as if it will never arrive.

## 4. Why this hurts building far less than it would hurt mining

Mining needs a *mobile* chunk-loading answer because **the work area moves**. A
miner walks its sectors continuously, so the loaded volume has to travel with it.
That is why the miner carries a loader turtle, places it, verifies the beacon,
swaps chunky for pickaxe, mines, then retrieves it — an entire subsystem
(`equipment.lua`, `loader_state.lua`, `geofence.lua`, `mine_flow.lua`) exists to
make that safe.

**A build site does not move.** Its full footprint is known before the first
block is placed, because the bridge parses the schematic and therefore knows the
bounding box exactly. That converts a hard mobile problem into an easy static
one:

- Compute the build's bounding box at parse time — the parser has to walk every
  block anyway.
- Blanket it with **static placed chunky turtles**. At 80×80 blocks of coverage
  each, **most builds need exactly one**, positioned once.
- The Android works entirely inside a pre-loaded volume. It never carries a
  loader, never swaps equipment, never verifies a beacon mid-task.
- Loaders go down at build start and come up at build end.

This is *less* infrastructure than mining, not more. None of `equipment.lua`'s
swap choreography is needed, and the geofence becomes a static bounding-box check
instead of a moving Chebyshev-in-chunk-space fence.

The loader blanket is also **role-agnostic** — it is needed whether the builder
is an Android or a turtle, since a builder turtle far from base has the same
problem. So it is not a cost attributable to the Android decision.

## 5. Residual risks — where Androids genuinely lose to turtles

These are the things I would not want discovered after the system is built.

**5a. The travel corridor, not the build site.** §4 solves the site. It does not
solve getting there. An Android walking from base to a distant site crosses
unloaded chunks and freezes. Three ways out, in descending order of strength:

1. **Station Androids at the site.** They arrive once and stay for the build.
   No corridor problem at all. This is the strongest option and the one I would
   build toward.
2. **Escort with a chunky-equipped turtle.** Verified possible in principle
   (§2, "travel" mode), but the escort must keep pace with entity-speed `moveTo`
   pathfinding while doing its own turtle-speed navigation. The 80×80 coverage
   gives generous slack, but this is the fragile option.
3. **Site is inside already-loaded area.** Fine when true, not a general answer.

**5b. An Android is an entity; a turtle is a block.** This risk is not in the
original design analysis and I think it is the most underrated one. `getSelf()`
returns a `health` field and the API includes `attack`, `getNearbyMobs`, and
`getClosestMob` — so Androids can be damaged, and presumably killed. An entity
can also be shoved by pistons, pushed by water, or fall. A turtle sitting in a
block position can be none of those things.

For an unattended overnight build, "the builder was killed by a creeper at 3am"
is a failure mode turtles simply do not have. What happens to the Android's
computer and inventory on death is **unknown and worth knowing** (probe D).

**5c. Computer state on chunk unload.** When a chunk unloads, a CC computer in it
shuts down; on reload it boots and runs `startup.lua`. For an Android mid-build
that means re-registering with an in-flight job silently dropped. The existing
job model can recover from this — the column handshake would reassign — but only
if the column protocol is designed for it from the start, the way the mining
sector handshake was. Worth designing in, not retrofitting.

## 6. The counterfactual — what dropping Androids actually costs

Androids were chosen for exactly one reason: **`useBlock` is a real player
right-click, so block facing follows from approach angle.** `moveTo` south of a
target then `useBlock` yields a north-facing stair, with no lookup tables, no
try-verify-retry, and no XP cost.

A builder turtle gives that up. How much that matters is **not currently known**,
and I want to flag that the original analysis asserted the turtle approach was
worse without measuring it:

- `turtle.place()` / `placeUp` / `placeDown` derive facing from the turtle's own
  orientation, so **4 horizontal facings are reachable by rotating.** That covers
  a large fraction of directional blocks outright.
- What a turtle plausibly *cannot* control is the part of a click a turtle has no
  analogue for — top-half vs bottom-half slabs and stairs, which depend on where
  on the block face the click lands.

If probe C shows turtles hit most block states and only miss upper slabs/stairs,
the Android case weakens considerably, because the whole justification narrows to
a block subset that a schematic could simply avoid. If probe C shows broad gaps,
the Android case is strong and §5's risks are worth managing. **This single probe
carries more decision weight than the chunk-loading question does.**

## 7. Proposed in-world probes

Following the `tests/inworld/` precedent: one small program per question, each
answering something the design cannot be written without.

**Probe A — can an Android take or place a chunk loader?**
Two parts. (i) Does `chunk_controller` fit the Android's pocket upgrade slot at
all, and does the modem survive if it does? (ii) Can an Android hold a
`computercraft:turtle_advanced` and `useBlock` it into place? Part (ii) is the
valuable half — if an Android can deploy its own loader blanket, the build
sequence needs no turtle bootstrap step.

**Probe B — does a static loader blanket keep an Android ticking?**
The core premise of §4, and the `tick.lua` witness pattern applies almost
unchanged: give the Android a counting loop writing to a log, place one loader,
fly 300+ blocks away, return and read the gap. Include the control run that
`chunkloader-footprint.md` still lists as outstanding — break the loader, wipe
the log, confirm it stalls — so a pass cannot be explained by something else
holding the area loaded.

**Probe C — what block states can a turtle actually place?**
The counterfactual from §6, and the highest-value probe of the four. Give a
turtle stairs, slabs, logs, and a few directional blocks; attempt every
orientation; record which states are reachable and which are not. Run the same
list past an Android with `useBlock` for a direct comparison.

**Probe D — Android failure modes.**
What happens to an Android on chunk unload and on death: does the computer
survive, does inventory drop, does it reboot cleanly and re-register, and does
`startup.lua` bring it back without human intervention? Cheap to run, and it
decides whether an unattended overnight build is realistic.

Probes A and B are only worth running if C says Androids are worth keeping. **Run
C first.**

## 8. Recommendation

Do not treat this as Android-or-turtle. The chunk-loading objection does not kill
Androids, but it does mean an Android can never be the whole answer, and §5b
means it should not be trusted to work unattended without knowing its failure
modes.

The shape I would build toward:

- **Turtles do logistics.** Material staging, and placing/retrieving the static
  loader blanket. This code substantially exists already.
- **Androids do placement only**, stationed at the site inside a pre-loaded
  volume, never travelling under their own power mid-build.
- **The column protocol assumes builders die**, exactly as the sector handshake
  assumes miners do — reassignable columns, work recorded server-side, no state
  that only lives on the builder.

That last point holds regardless of which builder wins, so it can be specified
before the probes resolve.

**What I would not do yet:** write the `.litematic` parser or the BUILDER role.
Probe C can still redirect the builder choice, and both of those are shaped by
its answer.

## 9. Unrelated finding

While reading `android_base.lua` for this study, two pre-existing defects, noted
here so they are not lost — neither is caused by anything above:

- **Refuel uses the wrong mechanism.** [android_base.lua:63](../../../android_base.lua)
  does `swapHands` → `refuel` → `swapHands`, assuming redstone sits in the
  off-hand. The API reference concluded this should be
  `equipSlot(slot)` → `refuel()` → `storeItem(slot)`, since the ender modem is a
  pocket upgrade and the main hand is therefore free.
- **The parallel-inbox bug is latent.** The Android runs one loop today, so its
  direct `proto.receive` calls are safe. The moment a build job runner runs
  alongside the heartbeat under `parallel.waitForAny`, it hits the same
  event-stealing failure that forced the shared inbox into `turtle_base.lua`
  at v1.8.1. The Android needs the `base.receive` inbox split **before** the
  builder role lands, not after.
