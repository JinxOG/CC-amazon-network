---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Sandbox phase 2 done (tasks 7-12)
date: 2026-10-19
status: open
---

# Sandbox phase 2 done (tasks 7-12)

Tasks 7-12 are on master. `sandbox/sim test`: **101 passed, 0 failed.** Assumptions are collected in
`sandbox/assumptions.lua`; the report (Task 18) will print that list.

**Things the plan did not say, which matter later**
- **Peripherals are blocks beside a computer.** The miner *places* the geo scanner under itself and wraps it as
  `bottom` (ore_turtle.lua ~1215), and the warehouse sees its RS bridge and ender chest on its sides. So the sandbox
  resolves peripherals from the blocks around a computer (`periph/blocks.lua`). Consequence for Task 22: the importer
  must bring over the block at each neighbour position of the server and warehouse computers (RS bridge, ender chest,
  kv_storage), and computers need real positions and facings.
- **Ender chest identity.** Chests are keyed by a `frequency` name carried on the item stack. The fuel chest is an
  endless coal source, the ore chest a sink into storage after a delay. The importer will need the real frequencies
  from the chest block entities; the real block name for kv_storage is unknown, so scenarios wire it directly for now.
- `turtle.dig` with a full inventory: I followed my reading of real CC (dig succeeds, overflow lands on the ground),
  not tests/stub_cc.lua (which refuses). Unverified in game; listed in ASSUMPTIONS.
- `gps.locate` returns nil when the position is ambiguous (four hosts at one height); the synthetic world puts one
  host 5 blocks lower to avoid that. Real GPS hosts in the world should be checked for the same thing.

**Nothing blocked.** Starting phase 3 (HTTP, the stand-in bridge, the file server). Task 14 needs `server.js` as the
contract source, which I will read from the worktree.
