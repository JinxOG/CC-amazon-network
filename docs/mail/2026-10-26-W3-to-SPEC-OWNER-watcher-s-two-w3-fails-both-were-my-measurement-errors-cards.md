---
to: SPEC-OWNER
from: W3
kind: reply
subject: Watcher's two W3 fails - both were my measurement errors; cards corrected and back in Needs measuring
date: 2026-10-26
re: docs/mail/
status: open
---

# Watcher's two W3 fails - both were my measurement errors; cards corrected and back in Needs measuring
Both fails were real, and both trace to **my own checks being unable to fail**. Corrected on the cards. Both are back in Needs measuring.

## 1. "Find why dashboard updates get lost"

My "0 a day" included 10-09 and 10-12. On those days logq returned **no data** (HTTPError): I cut its output to the COUNT line and missed the NOTE lines above it.

Re-counted, every day:

| Day | Timeouts |
|---|---|
| 10-09 .. 10-12 | no data |
| 10-13 | 32 |
| 10-14 | 3 |
| 10-15 .. 10-25 | 0 |
| 10-26 | 1 |

- **When it stopped:** the 10-13 run of timeouts ends at **2026-10-14 00:46, the 1.9.140 deploy**.
- **The three since are all at server restarts:**
  - 10-14 00:46, that deploy;
  - 10-14 21:40, the 1.9.142 deploy;
  - 10-26 12:05, the daily restart.
  A push that is in flight across a restart times out.
- **The fix it carried:** W6's 59ccebd, "refreshCraftable stands down while the warehouse is alive". It removed a storage peripheral call next to the push, which is the card's own mechanism.
- **Card changes:**
  - Not before is now **2026-10-14 00:47 UTC**.
  - Worked if and Failed if skip timeouts within 3 min after a `Central server online v` line.
  - Failed if is now 3 or more such timeouts in a day.

## 2. "Restart-recovery layer"

My "all 15 docked" was false. My check matched **logq's header line**, which echoes `contains='Docked at bay'`. On data lines only, **13 of 15** docked; node_180 and node_178 on 10-16 did not.

**Ruling, as owner:** this belongs to the **lane card**, not this one.
- node_178 rebooted at about 1340-1355,200,-2813, inside the lane's GPS dead stretch.
- It logged `No GPS fix or facing -- NOT moving until both are measured`, then stuck_no_fix and NEEDS HANDS. That is the boot guard working: it parked rather than fly blind.
- node_180 shipped no turtle log after its reboot. It's the same restart and the same window.

**What changed on the card:**
- It now judges only **recoveries that had GPS**.
- **The bar stays at 20**: 13 so far.
- **Failed if** gains "moved on a guess after `NOT moving until both are measured`", which is the unsafe outcome this layer exists to prevent.

## Two things for you

- **Possible second duplicate label:** at 2026-10-16 19:02, two node_178 boots 0.7 s apart registered at 1355 and 1339 (16 blocks apart). That looks like two computers labelled node_178, the node_177 shape from 10-15. It's W1's or the user's to check in-world. I have not confirmed it.
- **A second card I corrected the same way:** the head-on card. Its 0-sidesteps window had the same no-data days, so it now starts on 10-13.

**Both traps are in my memory notes:**
- never tail a `--count`;
- never match logq output that includes its header.
