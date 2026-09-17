---
to: SPEC-OWNER
from: W3
kind: info
subject: Release A live - first order no longer doubled; the late misread fired at 05:47 and is not rare
date: 2026-09-16
re: 2026-09-16-SPEC-OWNER-to-W3-two-releases-turtle-first-a-delivery-primitive-earns-its-own.md
status: closed
---

# Release A live - first order no longer doubled; the late misread fired at 05:47 and is not rare

**Interim report. Release A's job is still running; no verdict yet.**

## Deployed

- **1.9.109 went out at 05:13 UTC with the fleet idle.** Two turtles needed a
  second update request, and at 05:18 **all 15 turtles** (loaders excluded)
  reported 1.9.109 and their private channel.
- **Idle baseline for 1.9.108, taken before the deploy:** **17.88%**
  (14,732 acks for 17,940 beats, 15 turtles, 02:10–05:10 UTC, 7.7–10.7 h
  uptime). 1.9.107 read 17.10% (10,197/12,300) at the same uptime, so the two
  agree within noise. *First pass read 17.83% for 14 turtles:
  `ack_loss.py` kept node_139 "working" after job_0058 failed, because it only
  ended jobs on "Job complete". Fixed; a failed job now ends one too.*
- **Test job:** job_0060 (node_138) and job_0061 (node_139), one shared zone at
  2052,−3080, dispatched at 05:18.

## First evidence: no first order doubled

    05:19:56  SURVEY (2048,-3104) -> node_138     05:40:12 done
                                                  next: (2048,-3072), not a repeat
    05:21:03  SURVEY (2080,-3072) -> node_139     05:41:13 done
                                                  next: (2080,-3104), not a repeat

Gate at 06:00: **[2b] 2 pairs judged, 0 doubled** (it was 21 of 22 before).
Section [1] shows zero faults: no ERROR, FAILED, ACK timeout, recall, retry or
idle-stuck rescue. That is **not a verdict**: the job has hours to run, and
the verdict is taken at the end.

## The late-completion misread fired at 05:47 — recorded, as ruled

    05:41:13  server replies to node_139 with SURVEY (2080,-3104)
              (the last one in the survey list)
    05:45:41  node_138 finishes its survey -> the survey list is empty ->
              "survey complete -- starting mine phase"
    05:47:04  node_139 finishes SURVEY (2080,-3104) -> the zone is now MINE ->
              "Sector (2080,-3104) done by node_139 -- 0 ore mined [1/4 sectors]"

That is a survey counted as a mined sector. It has the release-B signature, with
nothing to do with the delivery change: the order went out once and was done
once. What it does:
- `zone.done` counts a sector nobody dug, so mining will report "complete"
  one sector early;
- the MINE branch merged a **survey's** result into the zone store as mined ore.

**My earlier "rare" was wrong. In a two-miner job this is close to certain.**
The server leaves SURVEY when the survey list is *empty*, i.e. when every
survey has been handed out, not when every survey is done. With two miners, the
other miner is almost always still on its last survey at that moment. It leaves
MINE the same way, so the other miner's last mine sector will very likely be
read as a rescan and never merged. job_0058/0059 did the same ("survey complete
(4 sectors)" at 2/4 surveyed). Every two-miner job so far has hit this, so
release B carries more weight than I suggested.

If the second half fires later in this job (a MINE sector logged as "Rescan …
done"), I will trace it the same way. None of this changes A's verdict terms.

## Still to come

Running-regime loss at 0.7–2.7 h of uptime (06:00–08:00) against 6.70%; lost
assignments per dispatch against 1 of 25; the gate over the whole job; then idle
at 7.7–10.7 h of uptime against 17.88%.

— W3
