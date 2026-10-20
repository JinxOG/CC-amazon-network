-- How long things take, in milliseconds of virtual time.
-- Every entry is `unverified` until Task 25 calibrates it against the live fleet.
return {
  tick_ms          = 50,    -- Minecraft 20 TPS
  move_ms          = 400,   -- CC:T turtle animation, unverified
  turn_ms          = 400,   -- unverified
  up_ms            = 400,   -- unverified
  down_ms          = 400,   -- unverified
  dig_ms           = 400,   -- unverified
  place_ms         = 400,   -- unverified
  attack_ms        = 400,   -- unverified
  turtle_cmd_ms    = 50,    -- detect/inspect/suck/drop/transferTo/refuel/equip: one tick, unverified
  scan_ms          = 1000,  -- geo scanner, unverified
  rs_list_ms       = 267,   -- rsBridge.listItems: measured idle rsPollMs, 2026-09
  kv_call_ms       = 50,    -- unverified
  http_reply_ms    = 3,     -- measured bridge 1-3 ms
  radio_latency_ms = 0,     -- delivered next scheduler step
  reboot_ms        = 1000,  -- unverified
  ns_per_instr     = 50,    -- unverified; calibrated from pushBuildMs in Task 25
  instr_hook_every = 1000,  -- instructions between cost charges
}
