# W5/W6 → spec owner: both briefs actioned, corrections taken, and what is *not* deployed

**From:** W5 (Bridge & Dashboard) / W6 (Storage & Refined Storage)
**To:** Spec owner
**Date:** 2026-08-29
**Re:** the two briefs of 2026-08-28, and `890850b`

---

## 1. Your corrections — both taken, one lands on my own spec

**The merge was never contested.** You are right, and my W5 reply repeated your
original premise instead of checking it. I should have verified `fc0af64`'s
position in the host's history before writing a section about preserving two
sides of a conflict that did not exist. Recorded so I do it the other way round
next time.

**The push timeouts were not the payload.** This one matters more, because I had
built on it. `2026-08-28-computer-split-design.md` justified extracting the
gateway *first* as targeting "a live failure (>15 s push timeouts)". That
justification is now wrong and the spec is corrected (`§2`, `§10`, revision note
in the header).

The case for the gateway survives; the urgency does not. Event-buffer overflow is
exactly the pressure the extraction relieves, and it is the same overflow that
kills the RS poll timer — but it is **hygiene, not a fire**, and it stays first
because it is the smallest and safest change, not because anything is burning.
`M4` has been rewritten to measure what the extraction actually relieves rather
than to chase a timeout that has since been explained.

Both errors ran the same way: a real measurement, and a story about it that was
not checked. That is what `S5` in the split spec exists for, and I have now
tripped over it twice in two days.

## 2. Done since the briefs

| | |
|---|---|
| **W5 §3** | RCON password from `process.env`, no default. No `.env` loader added — yours supplies it, mine consumes it |
| **W5 §5** | `uncaughtException` exits(1) on `EADDRINUSE`/`EACCES`/`EADDRNOTAVAIL` |
| **W5 §4** | `deploy/cc-dashboard.service` + README. systemd, not NSSM — §4.2 names the wrong platform |
| **W5 §4a** | `package.json` **and** `package-lock.json` committed. Verified by `npm ci` into an empty directory: 70 packages, both deps load |
| **W5 —** | `.gitignore` added. The repo had none, which is how `.env` gets committed on someone's first `git add -A` |
| **W6 §1** | Retry loop audited and **kept** — `4834fe6`, 2026-06-04, 22 days before the crash. Different failure, still real |
| **W6 §2** | All four `rsBridge` calls wrapped; crash restart + `wh_crash.log` parity with `central_server` |
| **W6 —** | First tests `warehouse.lua` has ever had. 6 assertions, all mutation-tested |

Suite: **280 passed, 0 failed.**

## 3. What is pushed but NOT deployed — the part I most want you to see

The host is running code that is **not** `master`, and `master` holds fixes the
host does not have. Live now: bridge up, `/state` 401, so your auth gate is
running from the host's own tree.

Not on the host, as far as I can tell:

| Commit | What | Needs |
|---|---|---|
| `aec4612` | **Updater hardening** + RS poll at 5 s | dispatch computer |
| `4aa7897` | RCON credential from env, `EADDRINUSE` exit, systemd unit, `package.json` | bridge host |
| `c0fa165` | Warehouse RS guards + crash restart | warehouse computer |

**The updater hardening is the awkward one.** It is the fix that stops a full
disk killing a deploy halfway — and installing it requires the very updater it
fixes. The dispatch computer had 417 KB free at last check against a 185 KB
server file, so there is headroom, but it is worth doing deliberately and
watching the output rather than firing `UPDATE_ALL` and hoping.

I have not deployed anything. Per standing rule, none of these restart on my say-so.

## 4. Open, and yours to call

**`admin_ui.lua` has no owner in §13.** I raised this on 2026-08-27 and it is
still open. It holds a **third `rsBridge`** at `admin_ui.lua:936`, which
contradicts §14's "W6 is the sole authority on Refined Storage access". Either it
gets an owner and that reader migrates to W6, or §14's wording needs softening.
It is a small thing that will bite exactly once, badly.

**`/self-update` runs `git pull` against a tree people edit by hand.** That is
what turned an operator's improvement into a deploy outage. Either the host clone
becomes read-only and changes arrive only through `master`, or `/self-update`
refuses loudly on a dirty tree. Today it does neither and surfaces as "deploys
stopped working" with no stated cause.

**The split spec needs a decision**, and specifically the `M1`–`M3` measurements
before anyone builds: how long `cloudstore.put`/`get` take at 44 KB and 125 KB,
and whether two computers contend. If KV is too slow the transport choice
collapses, and that is much cheaper to learn from a probe than from a rewrite.

**Recipe Registry** — my opinion is in the W6 reply: augment §11.7 with a
side-effect-free `RECIPE_QUERY`, keep `missing[]` as execution truth. Gated on
confirming the registry can expand a whole tree and reflects the modpack's
recipes rather than vanilla only. I am not speccing against an API I have not
seen.

## 5. One thing I could not verify

**RS import has not been confirmed working in-world.** The harness proves a
throwing import no longer kills the warehouse; it cannot prove 0.7.46r fixed the
throw. That needs a real delivery dispatched, which is a side-effecting action in
your world, and `/state` is now 401 so I cannot watch it either. One command and
one delivery when you want it.

## 6. Files I touched outside my streams

With the user's explicit authorisation each time, and documented in the relevant
memo: `central_server.lua` (RS poll interval, wall-clock fallbacks, update-failure
reporting), `updater.lua` (protected writes, in-place retry), and one line of
`tests/test_server_zones.lua`. W3 should read those before building on them —
that is a cost I imposed, and it is the same cost §14.1 records for W1.
