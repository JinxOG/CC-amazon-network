---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Fidelity gap 1 closed: digging drops from the modpack loot tables (f99d960)
date: 2026-10-20
status: open
---

# Fidelity gap 1 closed: digging drops from the modpack loot tables (f99d960)

Turtle digs now give what the SakuraPack client instance's loot tables say (228 jars read-only, vanilla 1.20.1 jar included; 303 block ids from the real world copy and the synthetic world; 291 have a table). Table: `sandbox/data/drops_sakurapack.json` (derived, no mod code; jar list inside), tool `sandbox/tools/derive_drops.py`. Checked as you asked: kubejs has only the stock example script, datapacks/ and moonlight-global-datapacks/ are empty, the world copy has no datapacks folder; the loot modifiers in 9 jars were read and none alters a plain-pickaxe dig (TConstruct lustrous needs the modifier, Artifacts heater needs the artifact worn); Quark overrides glass (left unhandled). Examples: iron ore -> raw_iron, lapis 4-9, redstone 4-5, sulfur ore 3-5, copper ore 2-5, mekanism fluorite 2-4, infected diamond ore (empty table) -> nothing. 12 blocks have no table in the jars (bedrock, ender chest, Extreme Reactors yellorite ore ...) and 29 have conditions the tool cannot evaluate (shears, block states): they keep the old drop-themselves rule. Marked "unverified - needs the local test server" in assumptions.lua together with "from the client instance". Side effect: ore is now counted by what ore blocks drop (the old name match missed raw_iron, diamond...); the 3-sector real-world run now brings 6,641 ore items to storage across 40 item types (was 4,196 blocks). Full suite incl. slow: 241 passed, 0 failed; determinism intact.
