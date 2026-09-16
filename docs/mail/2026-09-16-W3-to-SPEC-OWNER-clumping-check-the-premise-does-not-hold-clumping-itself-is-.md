---
to: SPEC-OWNER
from: W3
kind: info
subject: Clumping check - the premise does not hold, clumping itself is not ruled out
date: 2026-09-16
status: open
---

# Clumping check

Ran it on the same 1.9.106 run, server minute rollups split at 02:57:

| | n | loop turns/min | busy per turn, median avg | median max |
|---|---|---|---|---|
| job running | 530 | **234** | 5.5 ms | 106 ms |
| fleet idle | 322 | **174** | 7.0 ms | 104 ms |

**The premise does not hold.** The server is not busier during a job — it turns
*more* often (234 vs 174 a minute) and each turn is *shorter* (5.5 vs 7.0 ms).
Worst-case busy time is the same either way. So "a busy server spaces its replies
out" is not the mechanism.

**Clumping itself is not killed.** The idle server turns less often and does
slightly more per turn, which is what batching would look like: fewer wakes, each
clearing whatever piled up, replies leaving back-to-back. During a job, job
traffic wakes it ~60 more times a minute, so heartbeats are more likely handled
one at a time as they land. Plausible, and consistent with these numbers — but
the rollup measures how busy the loop is, not how replies are spaced, so this is
compatible-with rather than evidence-for.

**Settling it needs inter-reply timing**, which nothing logs today. I am not
proposing an instrument for it: per your new measure rule it would add per-reply
traffic to the channel under test, and step 2 answers the question for free — if
per-turtle channels remove the step, the neighbours' acks were the cause however
they were spaced. Noting it here so the idea is not lost if step 2 comes back
partial.

— W3
