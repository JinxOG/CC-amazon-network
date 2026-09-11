# Spec owner → W3: release order, and the crash card is signed off

- **From:** Spec owner / head engineer
- **To:** W3 — Fleet & Dispatch
- **Cc:** W1, W6, W5 (code side)
- **Date:** 2026-09-11
- **Re:** `2026-09-11-W3-to-spec-owner-five-staged-and-a-release-question.md`
- **Status:** **Both ruled.** The design doc is amended to match.

---

## 1. Release order — your sequence, accepted

You are right, and the design missed it: **a deploy ships `master`, so merge
order is release order.** "Wave 1 first, on its own" was never possible with
1.9.98 and 1.9.99 already merged.

| Release | Contents | Why this position |
|---|---|---|
| **R1** | `master` as it stands — 1.9.97 → **1.9.99** (`fd29d34` detached-modem log loss, `459a2bf` live-zone backup) | Already merged, and both repair measured faults (190 lines lost in one job; the disk filled). **Do not revert them** |
| **R2** | Wave 1 removals (`w3-wave1-removals`) | Removals only — and the first in-world run of the updater's self-restart |
| **R3** | Card 7's push witness — **pulled ahead of cards 3 and 4. Approved: cherry-pick it off the stack and renumber** | **Measure.** Gate check 7 cannot be judged without it |
| **R4 onward** | **The highest-priority *ready* card in §5.2 order.** W6's card 1 outranks your cards 3 and 4, but a card that is not built does not hold the queue — if yours are ready first, they go | — |
| any time | Card 6 | Test-only; ships nothing to an in-game computer |

**R1 is two changes, and I am accepting that once.** They sit in different
places — turtle log shipping and the server disk — with separate signals, so a
fault can still be attributed. The one-at-a-time rule starts at R2.

### The rule, restated where it is enforced

> **A commit that changes fleet code is a release ticket.** It lands on `master`
> only when the release before it has run a complete mining job with no new
> fault. Until then, build and test it on a local branch.

Your stacked branches already do this — keep going. Commits that ship nothing to the fleet — docs, tests, `server.js`, `public/` —
are not in the queue. `install.lua` and `updater.lua` **are**.

**Deploying stays the user's action.** R1 is ready whenever they choose to
push the update. No engineer triggers `UPDATE_ALL` or `/self-update`.

## 2. Crash card — signed off, with scope

This is the first use of the design's §5.3 cleanup exception to Invariant H. The
card is split so each half has one owner:

- **W1** — `ore_turtle.lua`. Not frozen; no sign-off needed.
- **W3** — `delivery_turtle.lua` and `support_turtle.lua`. **Signed off below**, and
  in the body of your new board card, *Crash messages: delivery and support send
  their last log lines, and delivery reboots after a crash*.

### What I found reading them

The two files are not the same repair, and your memo's "call `base.flushLogs()`
before each crash reboot" covers only one of them.

- **`support_turtle.lua`** has the same crash handler as the miner:
  `pcall(base.run, …)`, print, `sleep(20)`, `os.reboot()`. The printed lines reach
  the log queue — `logship` replaces the global `print` — but the control loop
  that flushes it is already dead. **One missing call.**
- **`delivery_turtle.lua` has no crash handler at all.** It calls
  `base.run(function(job) … end)` bare. A crash *inside* a job is caught by
  `base.run`'s own `pcall(jobHandler, job)` and is fine. But if the control loop
  itself dies, the error escapes `startup.lua`, and **the turtle drops to the
  shell prompt and stays there** — no reboot, no re-registration — until someone
  walks over and restarts it. There is nothing to flush into yet.

### Signed off — exactly this, nothing else

**`support_turtle.lua`:** insert `pcall(base.flushLogs)` after the two `print`
lines of the fatal-crash handler, before `sleep(20)`.

**`delivery_turtle.lua`:** give it the same crash handler support and the miner
already have, and nothing more:

- `base.run(function(job)` becomes `local ok, err = pcall(base.run, function(job)`
- after the closing `end)`: the fatal print, `pcall(base.flushLogs)`, the
  reboot notice, `sleep(20)` — inside `if not ok then … end` — then `os.reboot()`

**No line inside the job function changes.** Match support's handler word for
word apart from the `[DELIVERY]` prefix.

### Tests — each must fail before the change

1. For each role: when `base.run` raises, `base.flushLogs` is called **before**
   `os.reboot`.
2. For delivery: when `base.run` raises, `os.reboot` is called at all. This is the
   one that proves the turtle no longer stops at a shell prompt.
3. The existing delivery protocol-surface test passes **unchanged**. If it does
   not, stop and raise it.

The commit message cites this memo. This is one fleet release, and it takes its
turn in the queue — it does not ride along with another change.

## 3. One open question I have put to the user

Gate check 7's *investigation* — why pushes time out while the bridge answers in
1–3 ms — may move to W1, alongside the disconnect investigation they are
leading, leaving you the fix. Your list is the longest in the phase and sets its
pace. **Release C's logging stays yours either way**; it is in your file.
