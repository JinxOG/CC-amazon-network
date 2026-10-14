# Recovery Layer, Release 3: Generic Field Recovery and One "Recovering" Message

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A turtle of any role that reboots outside the base says so with one message, recovers what its ledger says it left out, flies home, and is released when it docks. The server's two miner-only triggers are replaced by that one message.

**Architecture:**
- `turtle_base.homeAfterBoot`'s outside-the-building branch is the single place every role passes after a field reboot. It sends `recovering: <where>` and runs `base.recoverLedger()` before any route.
- Every successful return home (`returnToDock`, `returnToDockInternal`, `returnToDockFromSky`) sends `docked`.
- The server's STATUS_UPDATE handler gains `registry.beginRecovery` (requeue the job it held, boot-recovery comms grace, `holdUntilDocked`) and releases on `docked`.
- MINE_PHASE `RETRIEVING (boot recovery …)` and `rebooted_outside_base` stop being triggers.

**Tech Stack:** Lua (CC:Tweaked); `lua tests/run.lua`; `python tests/mutate_logship.py`.

**Spec:** the ruling `docs/mail/2026-10-08-SPEC-OWNER-to-W3-W1-one-recovery-layer-approved-w3-builds-it-the-fuel-chest-is-e.md` §5, release 3: "Generic field recovery, and one server 'recovering' message replacing the two miner-only triggers … miner behaviour must be identical to today. Mutants that restore either old trigger must die."

## Global Constraints
- Edit only `turtle_base.lua`, `central_server.lua`, tests and the harness. `ore_turtle.lua` is W1's; its RETRIEVING and DOCKED phase reports keep working as reports.
- Miner outcome must be identical: the same requeue, the same RETURNING hold until DOCKED, the same boot-recovery comms grace.
- Mutants that restore either old trigger must die. A test pins "an old trigger alone no longer holds or requeues".
- Fields, not new file-scope locals. No new module.

## Review Focus
1. **The "recovering" message is lost on the radio.** Reliability equals the old single RETRIEVING report. Release 1.9.139's ACK-timeout path still requeues. *(Accepted; noted in the release mail.)*
2. **A delivery or support turtle held RETURNING that never sends "docked"** (its return failed). It must stay held: not dispatched while stranded. *Pinned in Task 1.*
3. **A miner's phase DOCKED and the new "docked" both arrive.** The release must be idempotent. *Pinned in Task 1.*
4. **Grace:** a recovering miner's radio-off flight must not be marked offline at the 60 s swap grace. *Pinned in Task 1.*
5. **A turtle inside the building but off its dock** must not send "recovering". *Pinned in Task 2.*

---

### Task 1: The server's one recovery message
**Files:** `central_server.lua` (STATUS_UPDATE handler; `handleMinePhase`; new `registry.beginRecovery`); test `tests/test_zone_phase.lua`.
- [ ] Failing tests:
  - `"a recovering report requeues its job, holds it, and gives it the long grace"`
  - `"a recovering turtle is released by docked, from any role"`
  - `"a recovering turtle that never docks stays held"`
  - `"an old boot-recovery phase report alone no longer holds or requeues"` (old trigger 1)
  - `"rebooted_outside_base alone no longer holds"` (old trigger 2)
- [ ] Make the existing boot-recovery tests send `recovering` first, then the phase reports, with the same expectations. That proves miner outcomes are identical.
- [ ] Implement:
  - `beginRecovery(id)`: take the requeue code from handleMinePhase's bootRecovery block; set `t.commsGapGraceSec = CFG.BOOT_RECOVERY_GRACE_SEC`; call `holdUntilDocked`.
  - A `^docked` detail releases the hold, as phase DOCKED does.
  - Delete the bootRecovery requeue/hold, and the `rebooted_outside_base` hold.
  - Keep the grace while `homeAfterReboot` is set (the phase reports must not reset it).
- [ ] Mutants:
  - restore old trigger 1;
  - restore old trigger 2;
  - no requeue;
  - no grace;
  - no release on docked.

  All must be KILLED. Commit.

### Task 2: Every role says so, and recovers before it flies
**Files:** `turtle_base.lua` (`homeAfterBoot`; the three return functions); tests `tests/test_shaft_sidestep.lua` and `tests/test_ledger.lua`.
- [ ] Failing tests:
  - `"a turtle rebooted outside the base says it is recovering"`: delivery, outside, after the measured position. Expect `recovering:` sent before any move.
  - `"a turtle rebooted outside the base recovers its ledger before flying home"`: fuel chest recorded where it stands. Expect it recovered, and the chest home, before the first move toward home.
  - `"a turtle inside the base but off its dock does not say it is recovering"`
  - `"a turtle that reaches its dock says docked"`
- [ ] Implement:
  - in the not-inside branch: `pcall(base.sendProgress, "recovering: " .. pos)` then `pcall(base.recoverLedger)`;
  - `docked` sent on each successful return.
- [ ] Mutants:
  - no recovering report;
  - ledger recovered after the flight;
  - no docked report.

  KILLED. Commit.

### Task 3: Release
- [ ] Run the full mutation suite and re-anchor anything MALFORMED.
- [ ] Bump the version, push, and verify the raw bytes.
- [ ] Deploy pinned with the fleet idle.
- [ ] Mail W1 and the spec owner. W1's one line is no longer needed: `homeAfterBoot` recovers the ledger first for miners too.
- [ ] Test with **one pair** and the user's back-to-back reboot. Record per role: recovering sent, ledger recovered, held until docked, no ACK-timeout dispatches.
