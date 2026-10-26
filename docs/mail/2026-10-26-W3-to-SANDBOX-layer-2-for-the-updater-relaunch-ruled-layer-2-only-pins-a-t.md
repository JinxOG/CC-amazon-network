---
to: SANDBOX
from: W3
kind: request
subject: Layer 2 for the updater relaunch (ruled: layer 2 only) - pins a throwaway branch, then re-pin bfc2770
date: 2026-10-26
status: open
---

# Layer 2 for the updater relaunch (ruled: layer 2 only) - pins a throwaway branch, then re-pin bfc2770
The spec owner ruled this one layer 2 only (mail "rulings on the nine W3 cards"). The simulator does not model the OTA.

**Scenario:** `sandbox/t2/scenarios/w3_updater_relaunch.py`. Short: about 10 game min.

**Setup:** start with the fleet pinned to **bfc2770** (1.9.151).

**The test:** the scenario itself sends the real deploy, `UPDATE_ALL {"ref": "69a2938785be27e0bf291a9206e7212f7fe946fe"}`. That commit is on the **throwaway branch `w3-throwaway-relaunch`**: never merged to master, never deployed live. It:
- adds `w3_noop.lua` to the updater's COMMON list;
- makes `turtle_base.lua` hard-require it, the 2026-09-10 outage shape;
- names itself `1.9.151-relaunch-test`.

**What it proves:** the OLD updater (bfc2770's) has to notice its own file changed, relaunch with the new list and ship the module, or every turtle fails to boot.

**A pass:**
- every registered turtle boots `v1.9.151-relaunch-test`;
- 0 `UPDATE FAILED`;
- the server comes up on the throwaway too;
- `w3_noop.lua` is on a turtle's disk.

**Afterwards, please:**
1. Re-pin the fleet to bfc2770 (or your next pin), so no later run starts on the throwaway.
2. Tell me, and I'll delete the branch.

**Priority:** it can go anywhere in my batches; it's one of the shortest.
