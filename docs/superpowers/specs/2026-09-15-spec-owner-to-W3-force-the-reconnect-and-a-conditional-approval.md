# Spec owner → W3: force the reconnect, and a conditional approval with its threshold set in advance

- **From:** Spec owner / head engineer
- **To:** W3 — Fleet & Dispatch
- **Cc:** W1, W5 (code side), W6
- **Date:** 2026-09-15
- **Re:** `2026-09-15-W3-to-spec-owner-a-protocol-change-and-a-retraction.md`
- **Status:** **Both ruled.** §2's approval is conditional and its threshold is
  written down here, before the data arrives, on purpose.

---

## 1. Retraction accepted — and force the reconnect

The retraction is accepted as written. The **method note is worth more than the
number**: "it fired somewhere inside a job that contained the bug" is the same
shape as every wrong close this project has made, and you caught it in your own
work. Correct the card body; the figure does not appear anywhere else I own.

**Ruling: force one.** A card that can only be closed by an event we are trying
to eliminate will sit open for ever, and §5.4 says no gate run starts while a
*Needs measuring* card is open. Waiting makes 1.9.104 permanently unvalidated.

**Conditions:**

1. **On an ordinary mining job, never during a gate run.** A forced interrupt
   during the 48 hours restarts the clock (§7.3).
2. **Reboot one miner mid-sector.** It is the smallest action that produces a
   genuine re-registration. Do not restart the server to make one — that changes
   the very thing under test.
3. **The user picks the moment.** It is their world and it may cost a sector of
   mining. Ask before, not after.
4. **The check must be able to fail.** "No repeat followed" is an absence, and an
   absence is also what a fix that never ran looks like. A valid capture needs
   **both**:
   - the **withheld-replay log line** for that node at that reconnect — proof the
     new code met the case and acted; and
   - **no repeated sector completion** after it.

   If no withheld-replay line appears, the test produced no evidence and the card
   stays open. That is a real outcome, not a failure of the exercise.
5. **One clean capture closes it.** Record job id, node, both timestamps and the
   evidence lines in the card body.

## 2. The per-turtle channel — approved conditionally, threshold set now

**It is a repair, not a feature.** It addresses a measured fault that blocks the
gate, so §3.1 allows it. The scaling benefit is a welcome side effect and is
**not** part of the justification — do not let it grow into scaling work.

### The condition, written before the data

You asked me to rule conditionally on 1.9.106's healthy baseline. Setting the
threshold **after** seeing the number is how a hypothesis survives its own
disproof, so here it is in advance:

| 1.9.106 says | Ruling |
|---|---|
| Healthy loop rate is **within 25%** of the disconnect-window figure — the loop is normally that slow | **Approved.** Ship the three releases |
| Healthy loop rate is **2× or more** the window figure — the loop normally keeps up and only sags in those windows | **Dropped.** The channel arithmetic is a consequence, not a cause. The question becomes *what makes the loop sag*, and that is a new card |
| Between 1.25× and 2× | Neither. Bring the numbers and we decide together — no default in this band |

**Also report a second number, because loop rate alone cannot settle it.** The
claim is that a turtle cannot drain its mailbox. Then measure the drain
directly: **messages arriving per second against messages handled per second,
while healthy.** If handled keeps pace with arriving in normal running, the
mailbox is not the bottleneck whatever the loop rate says, and I would drop the
proposal on that alone.

### If approved, these bind

1. **Three releases, in your order.** Turtles listen on both; then the server
   switches; then turtles stop opening the shared one.
2. **Step 2 is gated on evidence, not belief.** "Confirm all fifteen" must mean
   the turtles *report the channels they have open* — in `REGISTER` or the
   heartbeat — and all fifteen have reported the new one. A visual check of a
   fleet panel is the same class of assurance that produced the 1.9.94 outage.
3. **Derive the channel from the computer ID**, which `node_<id>` already comes
   from: `CH_PRIVATE_BASE (1000) + os.getComputerID()`. Deterministic, needs no
   coordination, survives a server restart, and cannot drift from the node id.
   If it would exceed 65535, fall back to the shared channel **and log loudly** —
   a documented degradation, never a silent one.
4. **Keep the `msg.to` filter permanently.** It is the backstop that makes a
   misrouted message harmless rather than wrong.
5. **Step 3 waits for a full job on step 2**, and `CH_BROADCAST` stays the recall
   path throughout.

### Related, and deliberately not now

`CH_LOCAL` has the same shape: every pair's coordination is heard by every
turtle. Nothing has measured it losing anything, so under §3.1 it stays alone.
Put it on the must-do list as known and deferred, with that reason, so the next
person to find it does not think it is news.

## 3. Release order

Agreed moot — 1.9.106 goes next.
