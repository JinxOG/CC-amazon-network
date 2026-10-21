-- How long things take, in milliseconds of virtual time.
-- Each entry says where its value comes from. "measured <date>" entries were fitted to the live fleet in Task 25
-- (docs/superpowers/specs/2026-10-20-sandbox-calibration.md); "unverified" entries are still guesses and are listed
-- as such in every report.
local T = {
  tick_ms          = 50,    -- Minecraft 20 TPS
  -- The six movement-class actions share one value, fitted so that a miner delivers a 25-ore batch every ~50 s, as the
  -- live fleet does (7,871 intervals over 2026-10-08/09/14/15/16: median 50.6 s). With 400 ms the sandbox gave 59-70 s.
  move_ms          = 300,   -- measured 2026-10-20 (fitted to live ore-batch cadence)
  turn_ms          = 300,   -- measured 2026-10-20 (same fit)
  up_ms            = 300,   -- measured 2026-10-20 (same fit)
  down_ms          = 300,   -- measured 2026-10-20 (same fit)
  dig_ms           = 300,   -- measured 2026-10-20 (same fit)
  place_ms         = 300,   -- measured 2026-10-20 (same fit)
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
