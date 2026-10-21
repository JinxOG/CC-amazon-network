-- How long things take, in milliseconds of virtual time.
-- Each entry says where its value comes from. "measured <date>" entries were fitted to the live fleet in Task 25
-- (docs/superpowers/specs/2026-10-20-sandbox-calibration.md); "unverified" entries are still guesses and are listed
-- as such in every report.
local T = {
  tick_ms          = 50,    -- Minecraft 20 TPS
  -- Per-action times, 2026-10-21. MEASURED in real CC:Tweaked on the local test server at 1x (sandbox/t2/scenarios/probe_actions.py,
  -- 20 calls each): forward, back, up and down 400 ms (8 ticks), turn 400 ms, dig of stone 384 ms, place 51 ms, detect /
  -- inspect / select / refuel 50 ms (1 tick), drop 365 ms, suck 400 ms, getItemCount / getItemDetail / getFuelLevel 0 ms
  -- (not main-thread tasks); failures are cheap: forward into a block 120 ms, dig with nothing there 84 ms, place with an
  -- empty slot 55 ms. With those measured values the sandbox's survey, ore-free sectors, rescans, re-mine and flight home
  -- all land within 4% of the real run, but its ore sector is 23% slow (11,600 s against 9,411 s): the real miner spends less
  -- time per dig and turn than the probe says. So `dig_ms` and `turn_ms` below are EFFECTIVE values fitted to the real
  -- ore-sector time (sandbox/tools/phase_fit.py --target t2, 12 runs; dig and turn trade against each other), not the
  -- measured 384 and 400. Why the real miner is cheaper per dig is open (calibration note, section 3).
  move_ms          = 400,   -- measured 2026-10-21 on T2 at 1x
  turn_ms          = 200,   -- EFFECTIVE, fitted 2026-10-21 (measured: 400)
  up_ms            = 400,   -- measured 2026-10-21 on T2 at 1x
  down_ms          = 400,   -- measured 2026-10-21 on T2 at 1x
  dig_ms           = 200,   -- EFFECTIVE, fitted 2026-10-21 (measured: 384)
  blocked_move_ms  = 120,   -- measured 2026-10-21 on T2 at 1x (probe_actions): forward into stone 119.8 ms
  dig_air_ms       = 85,    -- measured 2026-10-21 on T2 at 1x: dig with nothing there 84.4 ms
  select_ms        = 50,    -- measured 2026-10-21 on T2 at 1x (probe_actions): 50.0 ms
  drop_ms          = 365,   -- measured 2026-10-21 on T2 at 1x: 365 ms
  suck_ms          = 400,   -- measured 2026-10-21 on T2 at 1x: 400 ms
  place_ms         = 50,    -- measured 2026-10-21 on T2 at 1x (probe_actions): 50.8 ms
  attack_ms        = 300,   -- unverified (nothing to attack in the sandbox)
  turtle_cmd_ms    = 50,    -- detect/inspect/suck/drop/transferTo/refuel/equip: one tick, unverified
  scan_ms          = 1000,  -- geo scanner, unverified
  rs_list_ms       = 65,    -- measured 2026-10-20: median of 904 "RS probe: listItems" lines on 2026-10-17 (range 7-94 ms)
  kv_call_ms       = 50,    -- unverified
  http_reply_ms    = 3,     -- measured bridge 1-3 ms
  radio_latency_ms = 0,     -- delivered next scheduler step
  reboot_ms        = 1000,  -- unverified
  -- 150 ns per VM instruction reproduces the live server: pushBuildMs 17 ms (live 13, documented range 11-21) and a
  -- median loop busy time of 1.7 ms (live median 1.9). It under-reports rsBuildMs (19 ms against the live 64): the
  -- CC ROM's serialiseJSON costs more instructions than the sandbox's.
  ns_per_instr     = 150,   -- measured 2026-10-20 (live /state pushBuildMs, live loop rollups)
  instr_hook_every = 1000,  -- instructions between cost charges
}

-- For fitting runs only (sandbox/tools/phase_fit.py): SANDBOX_TIMINGS="move_ms=350,dig_ms=200" overrides entries. The
-- override string is kept in T.fitting_override so a fitting run can never pass for a default one.
local override = os.getenv("SANDBOX_TIMINGS")
if override then
  for k, v in override:gmatch("([%w_]+)=([%d%.]+)") do T[k] = tonumber(v) end
  T.fitting_override = override
end
return T
