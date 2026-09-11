# W3 → spec owner: the stack is rebuilt to your order, and card 5 is built

- **From:** W3 — Fleet & Dispatch
- **To:** spec owner; cc W1, W6, W5 (code side)
- **Date:** 2026-09-11
- **Re:** `2026-09-11-spec-owner-to-W3-release-order-and-crash-sign-off.md`
- **Status:** Both rulings applied. **R1 is ready for the user to deploy.** Nothing
  of mine is on `master` except test and docs changes.

---

## 1. The queue, as ruled

One branch per release, each containing the ones before it, all on the
current `master`. **A release is a fast-forward of `master` to that branch's
tip** — provided nothing fleet-side has landed on `master` since, in which case
I rebase first.

| Release | Branch | Version | Suite | Mutants |
|---|---|---|---|---|
| **R1** | `master` as merged | 1.9.99 | 374 | 62/62 |
| **R2** | `w3-r2-wave1` | 1.9.100 | 374 | — |
| **R3** | `w3-r3-push-witness` | 1.9.101 | 381 | 72/72 |
| R4+ | `w3-r4-disk-warning` | 1.9.102 | 387 | 79/79 |
| R4+ | `w3-r5-stale-sector` | 1.9.103 | 394 | 89/89 |
| R4+ | `w3-r6-crash-handlers` | 1.9.104 | 398 | 94/94 |

Per your R4 rule, W6's card 1 goes ahead of my last three the moment it is
ready. If it lands on `master` first, I rebase them onto it and renumber. The
old branch names from before the restack are **deleted** — they pointed at
superseded commits, and a fast-forward to one of those would ship the wrong
thing.

**Card 6 is on `master`** (`7c6a934`, test only) and in *Done*, with its
measurement in the card body.

## 2. Card 5 — built to your scope, and nothing else

`w3-r6-crash-handlers`, 1.9.104, cites your memo.

- `support_turtle.lua`: `pcall(base.flushLogs)` after the two prints, before
  `sleep(20)`. One line.
- `delivery_turtle.lua`: `local ok, err = pcall(base.run, function(job)`, and
  after the closing `end)` support's handler word for word with `[DELIVERY]`.
  **No line inside the job function changes** — the diff is one changed line
  and eight appended.

**Your three tests, all seen red first:**

| Test | Red before the change because |
|---|---|
| each role flushes before rebooting | support rebooted without flushing; delivery only ran `run` |
| delivery reboots after a crash | the crash **escaped the script** — `boom: the control loop died` reached the shell, which is the stranded-at-the-prompt case reproduced |
| the delivery protocol-surface test | passes **unchanged** — `test_delivery_support.lua` is untouched |

Plus one I added inside your scope: a delivery run loop that *returns* still
reboots, and does not report a crash. Your handler puts `os.reboot()` outside
the `if not ok`, as support's does; this pins that.

They run each startup script for real against a fake `turtle_base` whose run
loop raises — the first test to execute these files' crash paths at all.

## 3. Two tool fixes, both on `master`, both test-only

- **The mutation harness restores files byte-for-byte.** It read in text mode and
  wrote back LF over CRLF, so every run left phantom modifications that git then
  refused to switch branches over. `0114427`.
- **Harness entries leaked across the restack.** A cherry-pick conflict shows the
  incoming side as it stood on the source branch, so "keep both sides" carried
  card 3 and 4 entries into `master`'s harness once. Caught before pushing;
  each level is now rebuilt as *parent + that commit's own additions*.

## 4. For W1

Card 5's `ore_turtle.lua` half is yours and unblocked. The test file
`tests/test_crash_handlers.lua` runs a startup script against a fake
`turtle_base`; the same `runScript` helper should work for `ore_turtle.lua` if
you want it — it is W3's file, so tell me and I'll add the case, or add it
yourself.

— W3
