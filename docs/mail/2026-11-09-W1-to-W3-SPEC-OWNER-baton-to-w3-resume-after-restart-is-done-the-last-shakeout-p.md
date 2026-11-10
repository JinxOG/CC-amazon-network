---
to: W3,SPEC-OWNER
from: W1
kind: info
subject: Baton to W3: resume-after-restart is done, the last shakeout prerequisite
date: 2026-11-09
status: open
---

# Baton to W3: resume-after-restart is done, the last shakeout prerequisite
The resume-after-restart card is through both layers and the baton is yours for
SHAKEOUT 1 (per-bay types).

**Released as 1.9.161** (548f988; scenario and mutants through 50969f4). A miner
that reboots mid-job now resumes where it stands instead of flying home.

- **Layer 1**, both directions: on 1.9.161, 9 of 9 and MINING again **3.5
  minutes** after its boot line with no DOCKED line between, the job completing
  and no sector done twice. On the parent `ad29279`: 3 FAIL — no resume line, a
  DOCKED line, 10.0 minutes. A second arm covers a recall arriving while the
  turtle is down: it goes home, docks, names its reason, never claims to resume.
- **Layer 2**: run `w1-resume-c`, 1x, pinned and byte-verified, **6 of 6**, and
  INTERVENTIONS genuinely empty. Staged with `REBOOT_TURTLE`, which exists for
  exactly this.
- 826 unit tests, 9 of 9 resumeDecision mutants killed by their intended test.

**Measured cost it removes:** the 13:02 UTC daily restart, five miners mid-job
2,000 blocks out, about 36 minutes each from the restart to digging again,
nearly all of it a round trip to collect a job the server re-sends anyway.

**Two things in your file**, both additive, both mailed separately with the
reasoning: `base.setResumeIntent` (because `homeAfterBoot`'s `recovering:` is
read by the server as "flying home" and makes it requeue the job before the
role gets a say) and `base.setIdleAction` (so a miner holding position for a job
that was cancelled while it was down comes home after three idle minutes — it
cannot hear the recall, boot recovery having swapped its modem out for the chunk
loader). Reshape either if you want them elsewhere; `setIdleAction` looks like
the general hook the fleet has been missing.

**Open for the spec owner:** the all-roles half. Delivery and support are
frozen, so `mine_flow.resumeDecision` is pure and free of miner specifics
precisely so it can be lifted rather than rewritten.

**W1's other two cards are not startable by me.** The ore index is frozen behind
the cleanup exit gate (its biggest listed source of inaccuracy, the depth floor,
has landed). The flight-lane card needs evidence from a live job — the GPS
outage that blocked it is resolved, and the user is running a mining job and a
long-haul job now, which is where the next evidence comes from.

**Worth knowing before the 24-hour run**, all measured today and in the memory
notes: a rebooted turtle must keep its own sector order, because the server
withholds it on re-registration and `SECTOR_REQUEST` would hand out a different
sector; a turtle in boot recovery is deaf, so progress messages and recalls do
not reach it; and a RECALL sent between a reboot and re-registration is dropped
outright, which could matter in a boot rush.
