# The 13 server-only mods: what the pack pins, and what could be matched

Written 2026-10-20 by the sandbox builder. The user confirmed in chat (2026-10-20, after the Head Engineer relayed the
request): fetch them into the test server only, check hashes against the pack's record. Source of truth: the pack the
instance syncs from (`sync.bat`'s pack URL; its `pack.toml` and `index.toml`, saved under
`G:\TurtleOS-Sandbox\testserver\downloads\pack\`). Each mod's `.pw.toml` was checked against the sha256 the index records for
it, and each downloaded jar against the sha512 its `.pw.toml` records. Nothing is installed yet: the running cmp-1x
run keeps its mod set; the jars wait in `testserver\downloads\servermods\`.

## In the pack index and matched (8 of 13)

| Mod (side=server) | File | Download source | Hash check (sha512 of the jar vs the pack's record) |
|---|---|---|---|
| Get It Together, Drops! | getittogetherdrops-forge-1.20-1.3.jar | Modrinth CDN | **match** |
| In Control! | incontrol-1.20-9.5.0.jar | Modrinth CDN | **match** |
| Item Banning | itemblacklist-1.20.1-1.1.5.jar | Modrinth CDN | **match** |
| Lithostitched | lithostitched-forge-1.20.1-1.4.11.jar | Modrinth CDN | **match** |
| Structure Layout Optimizer | structure_layout_optimizer-forge-1.0.11.jar | Modrinth CDN | **match** |
| Tectonic | tectonic-3.0.17-forge-1.20.1.jar | Modrinth CDN | **match** |
| Too Fast | toofast-1.20-0.4.3.5.jar | Modrinth CDN | **match** |
| Village Spawn Point | villagespawnpoint-1.20.1-4.6.jar | Modrinth CDN | **match** |

## Not in the pack any more (5 of 13): removed on purpose, not a gap

The instance's own `packwiz.json` (what the client last synced) still lists these as `onlyOtherSide`, but the pack's
**current** `index.toml` (235 mod entries) has no entry for any of them, so there is no pinned file or hash to match:

- awesome-dungeon, awesome-dungeon-nether, awesome-dungeon-the-end
- mobs-properties-randomness
- yungs-better-mineshafts

The instance's `mods.zip` (a May 2026 snapshot) holds jars with those names (awesomedungeon-forge-1.20.1-3.2.0,
awesomedungeonend-forge-1.20.1-3.1.1, awesomedungeonnether-forge-1.20.1-3.1.1, mobspropertiesrandomness-5.1.7.2,
YungsBetterMineshafts-1.20-Forge-4.0.4), but they are not pinned by the current pack, so I did **not** treat them as a match.
Likeliest reading: the pack dropped them after the client's last sync (worldgen mods; the world is already generated).
Needs a ruling: leave the 5 out and name them as "not in the current pack", or use the old snapshot jars and say so.

## Also seen

The pack file pins Forge **47.4.10**; the test server runs Forge **47.4.20** (what the client instance launched with and what
the Modrinth app has). The live server's Forge version is not known to me.

## Rulings and answers (2026-10-20, the user via the Head Engineer, later)

- The 5 are leftovers: the user said "those mods are not on the current pack. We removed those. Those are just leftovers."
  So the client's `packwiz.json` entries for them are stale, they are not a gap, and they are NOT listed in NOT STAGED.
  The old `mods.zip` jars were rightly not used.
- The live server runs **Forge 47.4.10** for Minecraft 1.20.1 (`forge-1.20.1-47.4.10`), as the pack file pins. The user
  confirmed the download to me directly: official installer `forge-1.20.1-47.4.10-installer.jar` from Forge's maven, sha1
  `66bfea9963bfa60d88bab6b2750e74a958392715` (matches Forge's published sha1), installed into
  `G:\TurtleOS-Sandbox	estserver\server-47410\` (libraries only so far). The switch (new folder with the 227 client mods minus
  the 5 client-only, plus the 8 matched server-only mods) happens after the running 1x reference run finishes; every
  run report records the Forge version.
