# Codebase Audit — Design Spec
Date: 2026-06-04
Project: CC Amazon Network (v1.3.37)

## Goal

Systematically audit every source file in the codebase to produce a single consolidated bug report before any fixes are applied. Covers all three layers equally.

## Scope

### Categories
- `[CRITICAL]` — will crash or corrupt state at runtime
- `[BUG]` — incorrect behavior that won't crash (wrong output, bad logic)
- `[PROTOCOL]` — message sent but not handled, or handler exists for message never sent
- `[OVERSIGHT]` — missing edge case, silent failure, assumption that will eventually break
- `[PERF]` — unnecessary work, blocking calls, unbounded growth, memory issues
- `[OPT]` — optimization opportunity (minor, non-breaking improvement)

### Layers (equal priority)
1. **Turtle runtime** — `turtle_base.lua`, `delivery_turtle.lua`, `support_turtle.lua`
2. **Server layer** — `central_server.lua`, `warehouse.lua`, `waypoints.lua`, `protocol.lua`
3. **Dashboard/bridge** — `server.js`, `public/index.html`

## Audit Approach — Option A (Layer-by-Layer)

Files are read in dependency order so cross-file mismatches are visible while both sides are in context:

1. `protocol.lua` — shared message types, payload builders, channel constants
2. `waypoints.lua` — routing tables, waypoint math, return-route helpers
3. `turtle_base.lua` — movement engine, bypass logic, dock homing, bridge push
4. `delivery_turtle.lua` — job FSM, warehouse handshake, item distribution
5. `support_turtle.lua` — follow logic, chunk-load pairing, abort handling
6. `central_server.lua` — job dispatch, registry, bridge command handling
7. `warehouse.lua` — queue, chest export, batch state machine
8. `server.js` — Express routes, RCON, Dynmap proxy, command pipeline
9. `public/index.html` — dashboard UI, polling, per-item controls, modal

## Output

Single report file: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

Structure:
```
# CC Amazon Network — Codebase Audit Report

## Layer 1: Turtle Runtime
### turtle_base.lua
- [SEVERITY] Description — file:line — explanation

## Layer 2: Server Layer
...

## Layer 3: Dashboard / Bridge
...

## Summary Table
| # | Severity | File | Short description |
```

Report is committed to git before any fix is applied. Fixes are a separate pass after the user reviews the full report.

## Success Criteria

- Every source file read in full, no skipped sections
- Every finding includes: severity tag, file name, approximate line or function, plain-English explanation of the problem and its impact
- Protocol mismatches checked in both directions (sender side vs. handler side)
- Report committed; user approves before implementation begins
