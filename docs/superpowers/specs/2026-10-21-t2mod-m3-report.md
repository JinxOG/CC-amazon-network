# T2 control mod - M3 report: chunk unload under a loader

Date: 2026-10-21. Forge 1.20.1-47.4.10 (matches live), CC:Tweaked 1.120.2, Advanced Peripherals 0.7.46r, mod t2control 0.1.0.

## What M3 adds

`/t2 chunk unload area <x1> <z1> <x2> <z2> <seconds>` (Python: `chunk_unload(t, area=(x1, z1, x2, z2), dur=ms)`, the simulator's argument): every Forge chunk ticket on the chunks that overlap the block box is released, new ones for those chunks are refused for the duration, and at the end the old ones are put back. The computers inside the unloaded chunks shut down (CC's own behaviour) and boot again when the chunks return.

Also: `/t2 chunk unload <computer id> <seconds>` (release one Advanced Peripherals loader's own ticket), `/t2 chunk list` (the loader turtles whose computers are loaded right now), `/t2 chunk status`, `/t2 chunk tickets <cx> <cz>` (what holds a chunk loaded: type, level, mod, owner), `/t2 chunk probe <cx> <cz>` (asks Forge for a ticket through the same method every chunk-loading mod uses, and gives it back).

## The surprise that shaped the design

My first version released the Advanced Peripherals ticket of each loader turtle, as the spec says. The chunk stayed loaded. `chunk tickets` showed why: **this world is held by two chunk-loading mods, not one.** In the base's chunk, 18 tickets belong to Advanced Peripherals (the loader turtles) and 42 to a second mod, `chunkloaders` (the Chunk Loaders mod). Releasing only the turtles' tickets unloads nothing, because the other mod keeps the base alive on its own.

So the fault works one level down, at Forge's ticket system, which every chunk-loading mod goes through: it releases the tickets of ANY mod in the area. The refusal hook is on Forge's one private method that adds a ticket, so it covers all of them as well. This is also what the simulator's `chunk_unload(area)` means (the area is unloaded, whoever was holding it).

Plain meaning for the fleet: on the live server, taking away the loader turtles' tickets would not by itself unload the base while the Chunk Loaders mod holds it. A scenario that wants a real unload has to use the area form.

## Proof, both ways (run m3-a, `prove_mod.py m3`, 13 of 13)

| claim | evidence |
|---|---|
| the mod sees the loaders | 18 loader turtles listed |
| before the fault, the chunk is loaded and the computers are on | chunk (10,-176) loaded, 18 of 18 loader computers on |
| after the release, the chunk is unloaded and the computers are off | loaded=False, any loader computer on=False; 60 tickets released (18 Advanced Peripherals, 42 Chunk Loaders), 0 skipped |
| the refusal hook works | a ticket request inside the released area: refused (refusals 1); the same request 30 chunks away: accepted |
| the chunk can be forced back by other means and goes again | /forceload add: loaded; /forceload remove: unloaded again (the loaders do not re-hold it) |
| expiry puts everything back | chunk loaded, 18 of 18 loader computers on again, released=0 |
| after expiry the same request is accepted | accepted=True |
| the loaders are listed again | 18 of 18 |
| control: with no release, add and remove of /forceload leaves the chunk loaded | loaded=True |
| bad input | an unknown computer id answers with an error and changes nothing |
| intervention logged | `chunk_unload_area` in interventions.jsonl |
| no line dropped | 0 dropped |

Unit tests: `ChunkFaultsTest` (5): nothing refused by default, a released loader is refused until its duration ends and nobody else is, the refusal is lifted before the ticket is put back (and put back once), clear restores nothing, an area refuses every chunk inside it and restores once.

## Not covered

- Only the overworld is handled. Only Forge tickets (BlockPos or UUID owners) are released; vanilla `/forceload` tickets and Ticket types of other kinds are left alone (in this world there are none).
- The per-computer form is proven only for its error path; in this base it cannot unload anything on its own (see above), so it is not a useful fault here.
- A computer that was running a program when its chunk unloaded reboots from startup, like a real unload; what the fleet does after that is the scenario's business.
