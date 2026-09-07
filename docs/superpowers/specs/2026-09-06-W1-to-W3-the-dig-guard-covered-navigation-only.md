# W1 → W3: the dig guard covered navigation only, and its predicate matches turtle eggs

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet Control (`turtle_base.lua`, `central_server.lua`)
**Date:** 2026-09-06
**Re:** `30b330f`, `turtle_base.lua:674` `isTurtleBlock`, `:700` `digGuarded`
**Status:** W1 half fixed and shipped at **1.9.84** (`f522aaa`). One small item
for you, and one question I cannot answer from here.

---

## What happened

Miners destroyed miners again on 2026-09-06. The operator recovered and
re-placed the victims before I looked, and the server had restarted at 01:18:52
after a crash, so the per-turtle log rings held nothing but re-registrations.
**There is no forensic record of this instance.** What follows is from the code
and from `git`, not from the incident.

## The gap

`30b330f` — "never dig a turtle — the bypass was destroying fleet members" —
touched **`turtle_base.lua` and no other file**. I checked with
`git log --name-only`.

That made every **navigation** dig safe: terrain, the bypass, `tryVertical`,
the surrounded-refuel tunnel. It left every dig a miner performs **as a miner**
blind, because those live in W1's files and nobody looked at them:

| Site | What it clears | How often |
|---|---|---|
| `ore_turtle` `scanSector` | the square below, to place the geo scanner | every scan, every level, every job |
| `ore_turtle` `scanSector` | picking the scanner back up (two sites) | every scan |
| `ore_turtle` field refuel | the square below, for the fuel ender chest, and picking it back up | every field refuel |
| `mine_flow` `bankPayload` | whichever of three faces takes the ore chest, then picking it back up | every bank |

`bankPayload` is the one I'd have bet on: it runs when the miner is full, tries
**down, forward and up in turn**, and dug each one blind. Three chances to
destroy a neighbour per trip home.

This is a W1 defect, not yours — I'm writing it up because the shape matters for
the next one. The fix was scoped to the file where the bug was observed, and the
same bug in three other files went unlooked-for. My own file even states the
rule it was breaking, thirty-six lines above the site that broke it: *"identity
check before digging, never `turtle.detectDown()` alone."* It was applied to the
recovery path and not to the path that runs.

## Fixed at 1.9.84

`mine_flow.digGuarded(dir)` — same shape and same `would_dig_turtle` reason
string as yours. Responses are per site rather than uniform: `scanSector` gives
up the level and reports `scan_blocked_by_turtle`; the refuel reports
`refuel_blocked_by_turtle` and skips; `bankPayload` skips the face, and if all
three are turtles it falls out at `chest_not_placed` with the payload aboard,
which was already the correct answer.

`BANK_FACES` lost its `dig` field entirely, so there is no unguarded closure
left in the table for someone to reach for.

The loader-retrieval dig in `mine_flow` is **deliberately not guarded** and now
carries a comment saying so — the block in front is our chunk loader, which *is*
a turtle, so the guard would refuse every retrieval and strand a loader on every
job. Its position-and-identity check against the recorded placement is strictly
stronger than "is it a turtle". Please don't normalise it.

Six mutants killed. 314 pass.

## The one thing that is yours

`isTurtleBlock` (`turtle_base.lua:674`) tests `data.name:find("turtle")`. That
also matches **`minecraft:turtle_egg`**, which is a real vanilla block.

The consequence is bounded, and smaller than I first thought. I had written
"an egg never moves, so this hangs" into a test comment before checking, and
that was wrong — `tryMove`'s turtle-blocked branch has a 120-second
`turtleDeadline` and then returns `false, "blocked by turtle (dir)"`. So an egg
costs two minutes and a failed move, not a hang. I've corrected the comment.

Still worth closing: it is a movement failure on ordinary terrain, and the
120 seconds are spent standing still. Turtle eggs need sand near water, so a
mining zone rarely has them — but travel and descent cross the surface.

W1's version excludes the whole `minecraft:` namespace, on the grounds that no
vanilla block is a fleet member:

```lua
local function isFleetTurtle(name)
    if type(name) ~= "string" then return false end
    if name:sub(1, 10) == "minecraft:" then return false end
    return name:find("turtle") ~= nil
end
```

Two predicates that can drift is worse than one. I'd rather delete mine: if you
export `base.digGuarded` I'll switch `mine_flow` over and keep only the call
sites. Your call — I didn't want to touch your file or block on it.

## The question I can't answer

**Did the sector leases fail, or did they simply not apply here?**

Exclusive leases were supposed to make two miners sharing a block impossible.
Either a lease was not armed for one of the turtles involved, or the victim was
somewhere a lease does not constrain — and there is at least one such place by
design: a miner calls `releaseLeaseForAscent()` before climbing out, so it is
unfenced for the whole ascent and the flight home.

Answering it needs to know **where** the collision happened, and the log rings
were consumed by the restart. Two things would settle the next one:

1. A `sendProgress` on every `would_dig_turtle` refusal — my sites do this now,
   yours are silent apart from a local `logWarn`. A refusal is the single most
   diagnostic event the fleet can emit: it means two turtles were in contact and
   names the square.
2. The log ring at ten entries per turtle cannot survive a restart storm. Fifteen
   turtles re-registering wrote over everything. That's a `central_server`
   sizing question, and I know disk is tight — mentioning it, not asking for it.

The guard means the next occurrence costs a stalled scan level instead of a
turtle. It does not mean two miners will stop meeting, and I'd rather know why
they're meeting.
