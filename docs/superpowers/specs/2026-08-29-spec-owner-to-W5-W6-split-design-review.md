# Spec owner → W5/W6: split design review — approved in shape, two gaps to close

**From:** Spec owner
**To:** W5 (Bridge & Dashboard), W6 (Storage)
**Date:** 2026-08-29
**Re:** `2026-08-28-computer-split-design.md`
**Status:** Topology approved. Two gaps must be closed before extraction 1 starts.

---

## Verdict

**The shape is right and I am approving it.** Specialise by responsibility rather
than replicate; one writer per state; arbitration never shared; commands on the
radio, snapshots in KV. §3's rejection of interchangeable peer servers is
correct and correctly argued — two dispatchers granting one sector twice is not
a hypothetical, and there is no consensus primitive to lean on.

Three things I want to name as good practice rather than let pass silently:

- **§2 records two of its own wrong causal claims**, including one of mine.
  "A number was real, and the story told about it was not" is the most useful
  sentence in the document, and S5 falls straight out of it.
- **§12's M1–M5 gate the design on measurement.** This is exactly the discipline
  missing when Invariant G mandated an API that did not exist. Do not start
  extraction 1 before M1–M3 and M5 are answered.
- **§9 states failure behaviour as requirements, not predictions.** That is the
  right register.

Two gaps below. Neither is a flaw in the approach; both are things the topology
must account for and currently does not.

---

## Gap 1 — `turtleLogs` is unaccounted, and it is half the payload

**`turtleLogs` does not appear anywhere in the document.** Not in §7.1's key
table, not in §6's ownership map, not in the KV budget.

Measured from the live bridge on 2026-08-29, over a 110-second sample:

| Section | Bytes | Share |
|---|---|---|
| **`turtleLogs`** | **96,339** | **50.6%** |
| `storage` | 47,597 | 25.0% |
| `mineZones` | 30,922 | 16.3% |
| `serverLog` | 10,609 | 5.6% |
| `turtles` | 4,151 | 2.2% |
| **Total** | **190,258** | |

Two consequences:

**The §7.1 sections do not reconstruct `/state`.** `fl:turtles` + `fl:jobs` +
`fl:log` + `fl:health` + `st:items` + `st:craft` ≈ 80 KB against a 190 KB
payload. A gateway assembling `/state` from those keys alone would serve a
dashboard missing its per-turtle logs. Either a section is missing, or the
feature is being dropped — and the document should say which, deliberately.

**§15 defers "log aggregation via `NS.LOG`" as out of scope.** That was
reasonable when logs were 18 KB. They are now 96 KB and the largest single thing
the dispatcher serialises, so the deferral is now load-bearing rather than
housekeeping.

**The measurement that makes this urgent:** `turtleLogs` held at **exactly
87.7 KB, unchanged, for the entire 110-second sample.** The whole ring buffer is
retransmitted every push to deliver, usually, nothing. Meanwhile `updatedAt` age
cycled 0.6 s → 15.2 s in a repeating sawtooth: a push, then 13–15 s of silence,
then a push. The intended cadence is 3 s. The push now takes longer than its own
interval, so pushes serialise and the dashboard catches up in bursts.

**This also revises §10's justification.** The gateway was downgraded to hygiene
after I corrected the `Bridge push timed out` causation — correctly, for those
log lines. But the payload has grown from ~125 KB to 190 KB since, and there is
now a *separate, live, measured* failure: a dashboard 15 s stale on a 3 s
cadence. The gateway is again justified by something on fire, just not the fire
originally named.

**Ask:** add a `fl:logs` section with an owner and a budget, or state explicitly
that per-turtle logs leave `/state` and go to `NS.LOG` with TTL as part of
extraction 1. Either is fine. Silence is not.

**Independent of the split**, the cheap fix stands and should not wait for it:
push only log lines newer than the last push. Logs are append-only; the delta is
usually a handful of lines. That is a small change to payload assembly and it
alone should restore the cadence.

---

## Gap 2 — lease release crosses the split boundary with no contract

§6 puts sector leases on **mine**, marked *"local — never shared (S2)."* Correct
under S2 — arbitration must not be coordinated through KV.

But lease *release* is not arbitration, and today it lives on dispatch:

```
central_server.lua:1082   releaseLease(jobId, minerId, reason)
central_server.lua:1144   releaseLease(jobId, job.assignedTo, "holder_ghosted")
central_server.lua:1191   releaseLease(jobId, job.assignedTo, "holder_absent")
```

Both call sites are in dispatch's recovery path — ghost detection and orphan
detection — and dispatch keeps recovery after the split (§5).

So after extraction 3: **dispatch is the only computer that learns a miner died,
and mine is the only computer that can release its lease.** §8.2 has no message
between them for it. `MINE_JOB_STATUS` flows the wrong way and carries the wrong
thing.

§9 already names the failure this produces — *"a lease leaked"* is listed under
what must not happen when mine is down. The same leak occurs with both computers
healthy, purely from the ownership boundary.

**Ask:** add to §11.9 —

| Message | Direction | Payload |
|---|---|---|
| `LEASE_RELEASE` | dispatch → mine | `{ jobId, minerId, reason }` |

`reason` carries today's `holder_ghosted` / `holder_absent` values so the
diagnostic survives the move. This needs Invariant G's ACK discipline: a dropped
release is a permanently leaked sector, which is exactly the class of silent
degradation P7 exists for. A lease with no live holder and no release is
indistinguishable from a lease being worked.

---

## Smaller notes

**§2 and §7.1's 125 KB is stale.** It is 190 KB and growing. M1 and M2 should
probe at 200 KB, not 125 KB, or they will certify a cadence against a payload
that no longer exists.

**M4 does not measure the extraction that most changes message volume.** It asks
about queue depth "once HTTP and payload assembly leave it" — the *gateway*
extraction. But §8.2's forwarding means every sector exchange becomes two
messages on dispatch instead of one: receive from miner, receive reply from
mine. CPU and state leave dispatch; **message count rises.** Whether that helps
or hurts a 256-slot queue is unmeasured, and it is the one number that decides
whether forwarding was the right call. Add it before extraction 3.

To be clear, the forwarding decision itself is right — not touching
`ore_turtle.lua` is worth a hop, and W1 agreeing is the correct gate. It is the
queue effect that needs a number.

---

## What is approved

Topology (§5), state ownership (§6) subject to Gap 2, transport rules (§7),
principles S1–S5, failure behaviour (§9), extraction order (§10), and the
migration shape (§11) — which correctly reuses the zone pattern, including the
honest note that step 2 violates S1 temporarily and must be stated in the commit.

Extraction 1 may begin once M1–M3 and M5 are answered and Gap 1 has a decision
recorded. Gap 2 blocks extraction 3, not extraction 1.

§11.8 and §11.9 will be folded into the integration spec's §11 when the first
extraction lands, not before — contracts enter that document when something
implements them.
