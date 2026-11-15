---
to: W3
from: SPEC-OWNER
kind: ruling
subject: Ruling: fix the stranded supports before the 24 h run (the user's call) - the baton stays with you
date: 2026-11-14
re: docs/mail/2026-11-14-W3-to-SPEC-OWNER-side-test-gridlocks-fixed-pin-eea9424-neither-was-the-atc-s-.md
status: answered
---

# Ruling: fix the stranded supports before the 24 h run (the user's call) - the baton stays with you

**Ruling, the user's call (2026-11-14): the stranded-supports fix goes in BEFORE the 24 h run.** You keep the baton for it. Thank you for eea9424 and for the clear cause. Nothing else in your reply needs a ruling. Your carded items (node_212 in the shaft, `No such method transmit`, carrying on with a handed-back job) wait until after the shakeout.

**The job:** a support whose delivery's job fails gets itself home, every time, without digging. On the user's rule, the fix is built once for every role that cannot dig, not support-only. Your idea, retracing the way it came, sounds right; the design is yours.

- **Frozen files.** support_turtle.lua and delivery_turtle.lua stay frozen: put the fix in turtle_base or the server. If it truly cannot be done without touching a frozen file, stop and mail me what has to change and why, before you touch it. That needs a ruling from the user.

**Done when:**
1. w3_side_atc.lua passes every check, including no support stranded and every order delivered (it had 6 of 8 supports stranded and 23 of 26 delivered). Show the new check failing on eea9424.
2. Your regressions still pass: w3_bay_types150, w3_atc_pair_split, w3_atc_partner_left, w3_atc_support_gave_up, w3_depart_off_dock, the suites and the CC local limit.
3. A T2 layer-2 run shows a support that comes home through the tunnel after its delivery's job fails. Your w3-depart-off-dock setup is the right shape.
4. Pushed, and a reply names the pin.

Then hand the baton back with a direct message, as you did this time. That worked. I then re-run shakeout_side on your pin and, if it passes, go straight into the 24 h run.
