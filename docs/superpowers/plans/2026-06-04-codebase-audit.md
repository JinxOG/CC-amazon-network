# Codebase Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read every source file in the CC Amazon Network, document all bugs, oversights, protocol mismatches, performance issues and optimizations into a single consolidated report, then fix everything in severity order.

**Architecture:** Two-phase execution. Phase 1 (Tasks 1–11) produces the audit report by reading each file in dependency order and writing findings. Phase 2 (Tasks 12–17) applies fixes from the report in severity order (CRITICAL → BUG → PROTOCOL → OVERSIGHT → PERF → OPT), then bumps the protocol version and pushes.

**Tech Stack:** ComputerCraft Lua (turtles + servers), Node.js/Express (bridge), vanilla HTML/JS (dashboard)

---

## Phase 1 — Audit & Report

### Task 1: Initialize Report File

**Files:**
- Create: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

- [ ] **Step 1: Create the report skeleton**

Write the following to `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`:

```markdown
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

*(findings go here)*

### waypoints.lua

*(findings go here)*

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

```

- [ ] **Step 2: Commit skeleton**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: initialize report skeleton"
```

---

### Task 2: Audit protocol.lua

**Files:**
- Read: `protocol.lua` (283 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- Every `proto.MSG` key: is it sent somewhere AND handled somewhere?
- `proto.decode` — does it accept all message types turtles actually send?
- `proto.receive` — timer event field name (`side` used for timer ID — is that correct for CC?)
- Payload builders — are all fields actually used by receivers?
- Channel constants — do any two subsystems use the wrong channel?
- `proto.send` uses `proto.CH_SERVER` as reply channel always — is that always right?

- [ ] **Step 1: Read protocol.lua in full**

Use the Read tool on `protocol.lua`.

- [ ] **Step 2: Check proto.receive timer event**

In CC Lua, `os.pullEvent()` returns `(event, timerID)` for timer events — the second return is the timer ID, not a "side". The current code uses `side == timer` which compares `timerID == timer`. Verify whether this is correct or a latent bug.

- [ ] **Step 3: Check proto.send reply channel**

`proto.send` always uses `proto.CH_SERVER` as the reply channel. Verify whether turtles sending on CH_BROADCAST or CH_PRIVATE ever need a different reply channel.

- [ ] **Step 4: Cross-reference all MSG keys**

List every key in `proto.MSG`. For each, note: where is it transmitted? Where is it handled? Flag any with no sender or no handler.

- [ ] **Step 5: Write findings to report under `### protocol.lua`**

Replace the `*(findings go here)*` placeholder with actual findings. Use format:
```
- [SEVERITY] `functionOrLineRef` — description of problem and its impact
```
If no issues found, write `- No issues found.`

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: protocol.lua findings"
```

---

### Task 3: Audit waypoints.lua

**Files:**
- Read: `waypoints.lua` (284 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- `W.internalReturnRouteFrom` — each waypoint should change exactly ONE axis. Verify.
- `W.internalReturnRoute` compatibility wrapper — does it produce the same result as calling `internalReturnRouteFrom(dock, dock.junction.x, W.RED_Z)`? Check the argument order.
- `returnAisleZ(dock)` — what happens if `dock.row` is out of range?
- All waypoint tables: do X/Z values reference named constants or magic numbers?
- `W.dockFacing` — does it return valid facing (0–3) for all dock positions?
- Any nil-safety issues if `dock` fields are missing?

- [ ] **Step 1: Read waypoints.lua in full**

Use the Read tool on `waypoints.lua`.

- [ ] **Step 2: Trace internalReturnRouteFrom axis changes**

For each waypoint in the returned route, verify which axis changes relative to the previous point. Any waypoint that changes both X and Z simultaneously is a bug (move.to will pick arbitrary axis order and may cross occupied rows).

- [ ] **Step 3: Check magic numbers vs constants**

Identify any raw coordinate literals. If a coordinate appears in more than one place without a named constant, it's an oversight (single change to the warehouse layout will silently break routes).

- [ ] **Step 4: Write findings to report under `### waypoints.lua`**

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: waypoints.lua findings"
```

---

### Task 4: Audit turtle_base.lua

**Files:**
- Read: `turtle_base.lua` (1191 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- `move.to` while loops: facing recalculated each step (fixed in v1.3.31) — confirm fix is complete and correct
- `bypassForward` — vertical bypass gate `_self.pos.y < 66`: is 66 the right threshold? What is the actual depot floor Y?
- `bypassForward` strafe logic: after strafe + move, does the turtle restore its original facing?
- `gpsSync()` — what happens if GPS returns nil? Is it safe to continue?
- `returnToDockInternal` — calls `move.followRoute`. What if route is nil or empty?
- `base.setStatus` — does it always push to bridge, or only sometimes?
- `pushToBridge` — what if HTTP request fails? Is the error swallowed silently?
- `pushToBridge` response body: `handleBridgeCommand` called for each command — is it pcall-protected?
- Fuel check: what level triggers IDLE/abort? Is there a minimum to complete a return trip?
- `move.forward` / `move.back` / `move.up` / `move.down` — do they update `_self.pos` correctly in all cases (including failed moves)?
- Any global state that could leak between jobs?
- `base.waitForMessage` — timeout handling correct?

- [ ] **Step 1: Read turtle_base.lua lines 1–600**

Use the Read tool with `limit: 600`.

- [ ] **Step 2: Read turtle_base.lua lines 601–1191**

Use the Read tool with `offset: 600, limit: 600`.

- [ ] **Step 3: Trace gpsSync nil safety**

Find `gpsSync()`. Check what happens when `gps.locate()` returns nil (no GPS signal). Does the turtle crash, silently use stale position, or handle gracefully?

- [ ] **Step 4: Trace pushToBridge error handling**

Find `pushToBridge`. Check: (a) is the HTTP call in a pcall? (b) is `resp.readAll()` called before `resp.close()`? (c) are commands dispatched inside a pcall? (d) what happens if JSON parse fails?

- [ ] **Step 5: Trace bypassForward full flow**

Find `bypassForward`. Trace the strafe path: does the turtle end up at the correct position with the correct facing after a successful bypass?

- [ ] **Step 6: Write findings to report under `### turtle_base.lua`**

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: turtle_base.lua findings"
```

---

### Task 5: Audit delivery_turtle.lua

**Files:**
- Read: `delivery_turtle.lua` (524 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- Warehouse handshake FSM: all states (WAIT_ARRIVE → WAIT_PLACED → SEND_BATCH → WAIT_BATCH → WAIT_DONE) — are transitions complete? Any state that can stall forever?
- `sendArrived()` re-ping loop — correct interval and deadline math?
- `lastIReq` re-send of ITEM_REQUEST — is 60s the right interval? Does it reset correctly?
- Chest placement: what if a chest slot is occupied? Does the turtle report the error or silently fail?
- Item pulling from entangled chest: what if items don't arrive within timeout?
- RECALL handling mid-delivery: does the turtle clean up properly before returning?
- JOB_ABORT handling: does support turtle get notified?
- `waitTick` print — is deadline math correct (`os.clock()` vs `os.epoch`)?
- What happens if `params.destination` is nil or malformed?
- Any unprotected `peripheral.wrap` calls?

- [ ] **Step 1: Read delivery_turtle.lua in full**

Use the Read tool on `delivery_turtle.lua`.

- [ ] **Step 2: Trace warehouse FSM states**

Map out every state transition. For each state, identify: what message advances it? What is the timeout? What happens on timeout — retry, abort, or stall?

- [ ] **Step 3: Check os.clock vs os.epoch usage**

`os.clock()` returns CPU time, `os.epoch("utc")` returns wall time. If the wait loop uses `os.clock()` for a wall-clock deadline, the timeout will be wrong under any parallel coroutine load.

- [ ] **Step 4: Write findings to report under `### delivery_turtle.lua`**

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: delivery_turtle.lua findings"
```

---

### Task 6: Audit support_turtle.lua

**Files:**
- Read: `support_turtle.lua` (155 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- Does it listen on CH_LOCAL for all messages the delivery turtle sends (POSITION_UPDATE, ASCENDING, DESCENDED, RETURN_TO_DOCK, JOB_ABORT)?
- SUPPORT_STAGED handshake: what if the delivery turtle never ACKs? Does support stall?
- HOLE_READY: does support correctly descend and send SUPPORT_READY?
- After RETURN_TO_DOCK: does support correctly return to its own dock independently?
- JOB_ABORT: does support stop immediately and return?
- Any fuel check before starting follow sequence?
- What if the delivery turtle's position is never received — does support wander?
- Modem channel management: does it open and close channels correctly?

- [ ] **Step 1: Read support_turtle.lua in full**

Use the Read tool on `support_turtle.lua`.

- [ ] **Step 2: Map all CH_LOCAL messages support listens for vs what delivery sends**

List messages delivery_turtle sends on CH_LOCAL. List messages support_turtle handles. Flag any mismatch.

- [ ] **Step 3: Write findings to report under `### support_turtle.lua`**

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: support_turtle.lua findings"
```

---

### Task 7: Audit central_server.lua

**Files:**
- Read: `central_server.lua` (1040 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- `handleBridgeCommand` — are all command types handled? Any missing (e.g. DISPATCH_DELIVERY params validation)?
- `server.submitJob` — what if no turtles are available? Does job sit in queue forever?
- `server.cancelJob` — does it notify the assigned turtle? Does it reset turtle status?
- `pushToBridge` interval: 2s — what if the HTTP call takes longer than 2s? Do calls stack up?
- `state.registry` — is there a TTL on turtle records? Can a crashed turtle stay ASSIGNED forever?
- Heartbeat timeout: what happens when a turtle stops heartbeating? Status stuck?
- `recallAll` — does it only send RECALL or also reset status?
- `saveJobs` / `loadJobs` — is the file path safe? What if the file is corrupt?
- Job assignment: is the same job ever assigned to two turtles?
- Are all message handlers wrapped in pcall?
- `sendTo` — what if the target turtle is not registered? Silent drop?
- CLEAR_JOBS: loops `state.jobs` and sends RECALL — but `state.jobs` is then set to `{}`. Does the loop complete before the table is cleared?

- [ ] **Step 1: Read central_server.lua lines 1–520**

Use the Read tool with `limit: 520`.

- [ ] **Step 2: Read central_server.lua lines 521–1040**

Use the Read tool with `offset: 520, limit: 520`.

- [ ] **Step 3: Check pushToBridge concurrency**

Find where `pushToBridge` is called. Is it called from inside a coroutine? If the HTTP call blocks for >2s and the timer fires again, does a second push start concurrently, causing double-dispatch of commands?

- [ ] **Step 4: Check turtle TTL / heartbeat timeout**

Find the heartbeat handler. Determine: what is the timeout before a turtle is marked offline? Is status reset to IDLE or left as-is? Can a dead turtle block a job slot?

- [ ] **Step 5: Write findings to report under `### central_server.lua`**

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: central_server.lua findings"
```

---

### Task 8: Audit warehouse.lua

**Files:**
- Read: `warehouse.lua` (450 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- Auto-queue from DELIVERY_ARRIVED: does it correctly avoid duplicating queue entries?
- `chestsNeeded(items)` — does the math handle fractional chest needs correctly?
- Batch state machine: all states and transitions — can any state stall without a timeout?
- After ITEMS_DONE: does warehouse correctly reset `current` and advance the queue?
- `inboxPut` timing: if the entangled chest isn't clear, does warehouse retry or give up?
- What if a turtle disconnects mid-delivery (no BATCH_DONE ever arrives)?
- `sendToServer` — is it using the right channel? Does it address messages correctly?
- Queue position reporting (WAREHOUSE_QUEUED) — is position 1-indexed or 0-indexed?
- Any peripheral.wrap calls that could fail if the chest isn't attached?
- Log output: is there enough logging to diagnose a stall?

- [ ] **Step 1: Read warehouse.lua in full**

Use the Read tool on `warehouse.lua`.

- [ ] **Step 2: Trace the full batch state machine**

Map every state: what triggers entry, what message advances it, what is the timeout, what happens on timeout.

- [ ] **Step 3: Check entangled chest clear detection**

Find the code that checks whether the entangled chest is empty before sending the next batch. What is the polling interval? What is the max wait? What happens if the chest never clears?

- [ ] **Step 4: Write findings to report under `### warehouse.lua`**

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: warehouse.lua findings"
```

---

### Task 9: Audit server.js

**Files:**
- Read: `server.js` (185 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- `/update` POST: `pendingCommands.splice(0)` — is this atomic? Can a command be lost if two CC pushes arrive simultaneously in Node's event loop?
- `state.turtles` — does it ever get cleaned up? Can it grow unbounded?
- `markerExists` — same unbounded growth concern
- `upsertMarker` — called with `.catch(()=>{})`, so errors are silently swallowed. Is that intentional?
- RCON reconnects on every call — is this necessary? Could it be pooled?
- `proxyDynmap` — no timeout on upstream HTTP request. If Dynmap is slow, does the dashboard request hang forever?
- `/command` route — no rate limiting or authentication. Any turtle ID can be targeted.
- `state.version` — only set when CC pushes include it. What is the initial value? What does the dashboard show before first push?
- `express.json()` body size limit — default 100kb. Is a full turtle registry + jobs payload within that?
- Error handler for unhandledRejection logs but doesn't crash — is that right for a production service?

- [ ] **Step 1: Read server.js in full**

Use the Read tool on `server.js`.

- [ ] **Step 2: Check pendingCommands race condition**

`splice(0)` in Node.js is synchronous and JS is single-threaded, so it is atomic within one event loop tick. However: if CC polls faster than 2s, two `/update` POSTs could both call `splice(0)` and split the command queue. Verify the CC push interval vs risk.

- [ ] **Step 3: Check state object growth**

Identify all keys added to `state.turtles` and `markerExists` over time. Determine if any cleanup path exists for turtles that go offline permanently.

- [ ] **Step 4: Write findings to report under `### server.js`**

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: server.js findings"
```

---

### Task 10: Audit public/index.html

**Files:**
- Read: `public/index.html` (899 lines)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- Polling interval — how often does the dashboard call `/state`? Is there error handling if the fetch fails?
- Version display — is `state.version` correctly extracted and shown in the header?
- Per-item CANCEL button — does it POST `CANCEL_JOB` with the correct `jobId`?
- Per-item IDLE button — does it POST `SET_IDLE` with the correct `turtleId`?
- CLEAR ALL JOBS button — does it POST `CLEAR_JOBS`?
- SET ALL STATUS TO IDLE — does it POST `RESET_STATUS`?
- Dispatch modal — does it correctly serialize X/Y/Z as numbers (not strings) in the POST body?
- Dynmap iframe `visibility:hidden` — is it restored correctly after modal closes?
- What happens if `/state` returns stale data (CC server offline)? Is there a staleness indicator?
- Tab switching — does it clean up any intervals or listeners?
- XSS: are turtle IDs or status strings ever injected into innerHTML unsanitized?

- [ ] **Step 1: Read public/index.html lines 1–450**

Use the Read tool with `limit: 450`.

- [ ] **Step 2: Read public/index.html lines 451–899**

Use the Read tool with `offset: 450, limit: 450`.

- [ ] **Step 3: Check XSS risk**

Search for all `innerHTML` assignments. For each one, determine whether the value comes from server state (turtle IDs, status, job IDs). If yes and values are not sanitized, flag as [BUG] (turtle label injection).

- [ ] **Step 4: Check dispatch modal number serialization**

Find the dispatch modal submit handler. Verify that `x`, `y`, `z` are sent as `Number(...)` not raw string values from the input fields.

- [ ] **Step 5: Write findings to report under `### public/index.html`**

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: public/index.html findings"
```

---

### Task 11: Cross-Layer Protocol Check & Finalize Report

**Files:**
- Read: audit report (current state)
- Modify: `docs/superpowers/specs/2026-06-04-codebase-audit-report.md`

**What to check:**
- Every `proto.MSG` key: has a sender been found AND a handler been found across all files?
- Bridge command types sent from `public/index.html` — are all handled in `handleBridgeCommand` in `central_server.lua`?
- Bridge command types in `handleBridgeCommand` — are all reachable from the dashboard?
- Version number in `protocol.lua` vs what `central_server.lua` sends to bridge vs what `server.js` stores

- [ ] **Step 1: Build the full MSG cross-reference table**

For each key in `proto.MSG`, fill in:
| MSG key | Sender file | Handler file | Gap? |

- [ ] **Step 2: Build the bridge command cross-reference table**

For each command type POSTed from `index.html`, verify it exists in `handleBridgeCommand`. For each case in `handleBridgeCommand`, verify the dashboard has a button/trigger for it.

- [ ] **Step 3: Fill in the Summary Table**

Replace the summary table placeholder with all numbered findings from every section. Assign sequential numbers. Sort by severity (CRITICAL first).

- [ ] **Step 4: Commit final report**

```bash
git add docs/superpowers/specs/2026-06-04-codebase-audit-report.md
git commit -m "audit: finalize cross-layer check and summary table"
```

- [ ] **Step 5: Present report to user**

Output the full summary table to the terminal so the user can see all findings before Phase 2 begins. Ask the user to confirm before proceeding to fixes.

---

## Phase 2 — Fixes

> Phase 2 begins only after the user has reviewed and approved the Phase 1 report.

### Task 12: Fix All CRITICAL Issues

**Files:** Determined by Phase 1 findings.

- [ ] **Step 1: List all [CRITICAL] findings from the report**

Read the summary table. Extract every row tagged CRITICAL. Order them by the dependency layer (protocol → waypoints → turtle → server → dashboard).

- [ ] **Step 2: For each CRITICAL finding, apply the fix**

For each finding:
1. Read the affected file at the indicated line/function
2. Apply the minimal fix that resolves the issue without changing unrelated behavior
3. Verify the fix is correct by tracing the logic mentally

- [ ] **Step 3: Commit all CRITICAL fixes**

```bash
git add <affected files>
git commit -m "fix(critical): <short summary of all critical fixes>"
```

---

### Task 13: Fix All BUG Issues

**Files:** Determined by Phase 1 findings.

- [ ] **Step 1: List all [BUG] findings**

- [ ] **Step 2: Apply each fix, smallest scope first**

- [ ] **Step 3: Commit**

```bash
git commit -m "fix(bug): <summary>"
```

---

### Task 14: Fix All PROTOCOL Issues

**Files:** Determined by Phase 1 findings.

- [ ] **Step 1: List all [PROTOCOL] findings**

- [ ] **Step 2: For each mismatch, determine which side is wrong (sender or handler) and fix the correct side**

- [ ] **Step 3: Commit**

```bash
git commit -m "fix(protocol): <summary>"
```

---

### Task 15: Fix All OVERSIGHT Issues

**Files:** Determined by Phase 1 findings.

- [ ] **Step 1: List all [OVERSIGHT] findings**

- [ ] **Step 2: Apply fixes**

- [ ] **Step 3: Commit**

```bash
git commit -m "fix(oversight): <summary>"
```

---

### Task 16: Fix All PERF and OPT Issues

**Files:** Determined by Phase 1 findings.

- [ ] **Step 1: List all [PERF] and [OPT] findings**

- [ ] **Step 2: Apply fixes, most impactful first**

- [ ] **Step 3: Commit**

```bash
git commit -m "perf: <summary>"
```

---

### Task 17: Bump Protocol Version & Push

**Files:**
- Modify: `protocol.lua`

- [ ] **Step 1: Increment protocol version**

Open `protocol.lua`. Find `proto.VERSION = "1.3.37"`. Increment to the next appropriate version (1.3.38 for a patch, 1.4.0 if any protocol-level changes were made).

- [ ] **Step 2: Commit and push**

```bash
git add protocol.lua
git commit -m "v<new-version>: post-audit fixes"
git push
```

- [ ] **Step 3: Report which computers need updating**

Output the update commands for: CC central server, delivery turtles, support turtles, warehouse computer.
