# CC Amazon Network — Codebase Audit Report
Date: 2026-06-04
Version audited: v1.3.37

Severity tags:
- [CRITICAL] — will crash or corrupt state at runtime
- [BUG]      — incorrect behavior, won't crash
- [PROTOCOL] — message sent but never handled, or handler with no sender
- [OVERSIGHT]— missing edge case, silent failure
- [PERF]     — blocking call, unbounded growth, unnecessary work
- [OPT]      — minor non-breaking improvement

---

## Layer 1: Turtle Runtime

### protocol.lua

- [BUG] `proto.send` — Hardcodes `proto.CH_SERVER` (1) as the reply channel for every transmit, regardless of the actual sender. This is correct for turtle→server traffic but wrong for server→turtle (CH_BROADCAST/CH_PRIVATE), warehouse (CH_WAREHOUSE), and turtle↔turtle (CH_LOCAL) messages: their `replyChannel` metadata falsely advertises channel 1. Currently latent because `proto.receive` discards the reply channel (`repCh` is captured but never used), so no code replies on it — but any future code that relies on `replyChannel` to route a response would send it to the server instead of the real sender. Should pass the sender's own listen channel as the reply channel.
- [OVERSIGHT] `proto.send` — Calls `textutils.serialise(msg)` on every send, while `proto.receive` accepts BOTH a raw table (`type(raw) == "table"`) and a serialised string. The send path never transmits a raw table, so the table branch in receive is dead unless some other (non-proto) sender transmits raw tables. Asymmetry is harmless but worth noting; serialise also throws on payloads containing functions/recursive tables, which would crash the sender rather than fail gracefully.
- [OVERSIGHT] `proto.receive` — `textutils.unserialise(raw)` returns `nil` on malformed input; the code guards with `local ok = msg ~= nil` and skips, so a corrupt/garbage modem message is silently dropped with no log. Acceptable, but failures are invisible for debugging.
- [OPT] `proto.receive` timer event — The destructure `local event, side, ch, repCh, raw = os.pullEvent()` reuses modem-message field names for the timer case, where the 2nd return is actually the timer ID. The check `event == "timer" and side == timer` is CORRECT (for a timer event `side` holds the timer ID), but the variable name `side` is misleading and invites future bugs. No functional issue. Naming it `p1`/`arg2` or handling timer with its own pull would be clearer.
- [OVERSIGHT] `proto.MSG` orphan-from-name scan — Most types map cleanly to a sender/handler. Two stand out by name: `ITEM_REQUEST`/`ITEM_READY` (older warehouse handshake) appear superseded by the newer `DELIVERY_ARRIVED`/`CHESTS_READY`/`ITEMS_READY`/`BATCH_DONE`/`ITEMS_DONE` handshake added below — possible dead/duplicate protocol pair to verify against actual senders/handlers. `TURTLE_QUERY`/`TURTLE_INFO` are documented as used by support turtles but the newer CH_LOCAL follow signals (`POSITION_UPDATE`, `ASCENDING`, `DESCENDED`) may make the server-mediated query path redundant. Flagged for cross-file confirmation in later tasks (handler/sender presence not verified here).
- No issue with the timer-ID check (Check 1), `proto.decode` MSG lookup (Check 4 — every `proto.MSG` entry has key == value, so `proto.MSG[msg.type]` validation succeeds for all valid types), terminate handling (Check 5 — `proto.receive` uses `os.pullEvent()`, the filtering form that re-throws `terminate` as an error, so Ctrl-T shutdown is NOT swallowed; `os.pullEventRaw` would have been the bug), or channel separation (Check 7 — channel is an explicit caller argument to `proto.send`, so CH_LOCAL messages are not auto-routed to CH_SERVER; only the reply-channel metadata is wrong, per the [BUG] above).

### waypoints.lua

- [OVERSIGHT] Hole coordinate literals duplicated across definitions — The X/Z literals `143`/`-2813` appear in `DISPATCH_HOLE`, `DISPATCH_STAGING` (x only), and `WORLD_EXIT`; `228`/`-2782` appear in both `ARRIVALS_HOLE` and `WORLD_ENTRY`. `WORLD_EXIT`/`WORLD_ENTRY` are by definition "below the dispatch/arrivals hole," yet they restate the raw coords instead of referencing `W.DISPATCH_HOLE.x/.z` and `W.ARRIVALS_HOLE.x/.z`. A single layout move of either hole requires editing the coordinate in two-to-three places, and forgetting one would put the underground entry/exit out of vertical alignment with its hole (turtle ascends/descends into a wall). Derive `WORLD_EXIT`/`WORLD_ENTRY` from the hole tables (only Y differs).
- [OVERSIGHT] Route builders deref `dock` fields with no nil guard — `aisleZ`, `returnAisleZ`, `departureRoute`, `supportDepartureRoute`, `returnRoute`, `internalReturnRouteFrom`, and `dockFacing` all access `dock.z` / `dock.x` / `dock.junction.x` without checking `dock` (or its fields) for nil. `W.getDockFor(role, turtleId)` (and `W.assignDock` on a full depot) can return `nil`; `central_server.lua:81` stores that result directly. If a nil/partial dock ever reaches a route builder, `W.WHITE_Z > dock.z` throws "attempt to compare number with nil" rather than failing gracefully. Turtle-side callers in `turtle_base.lua` happen to guard with `if not _self.dock`, so this is currently latent, but the helpers themselves are unsafe and a server-side caller has no such guard at the routing boundary.

Checks that passed (no issue): single-axis waypoint rule in `internalReturnRouteFrom` (all 5 steps change exactly one of X/Z relative to the prior step, starting from `fromX,fromZ`); the `internalReturnRoute` compatibility wrapper (calls `internalReturnRouteFrom(dock, dock.junction.x, W.RED_Z)` — argument order matches the spec; its only quirk is a harmless duplicate first waypoint when `fromX==junction.x` and `fromZ==RED_Z`); `returnAisleZ` does not index by `dock.row` at all (it derives from `dock.z`), so an out-of-range/nil `row` is irrelevant to it; `dockFacing` returns only `2` or `0`, both valid {0,1,2,3}; and `CFG.FLOOR_Y` is referenced via the config constant everywhere inside this file (the raw `67` literal lives in `turtle_base.lua:622`, out of scope for this task).

### turtle_base.lua

*(findings go here)*

### delivery_turtle.lua

*(findings go here)*

### support_turtle.lua

*(findings go here)*

---

## Layer 2: Server Layer

### central_server.lua

*(findings go here)*

### warehouse.lua

*(findings go here)*

---

## Layer 3: Dashboard / Bridge

### server.js

*(findings go here)*

### public/index.html

*(findings go here)*

---

## Summary Table

| # | Severity | File | Description |
|---|----------|------|-------------|
