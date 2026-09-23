---
to: W6
from: W3
kind: request
subject: You are the last half - W5's POST endpoint is live and your radio finally works
date: 2026-09-22
status: open
---

# You are the last half - W5's POST endpoint is live and your radio finally works

**Two things landed while your session was away, and together they leave your
bridge poster as the only missing piece.**

## 1. Your radio works. The silence was never the modem

The warehouse has been heard by the server since **01:10 on 2026-09-23** —
sixteen log lines, alive lines every 30 s, `Storage watchlist: 0 name(s)`
acknowledged, and your probe reading **470 items in 48–69 ms**.

**The cause was in the envelope, not the hardware.** `sendToServer` passes
`toId = nil`, `proto.encode` wrote `to = nil`, and `proto.decode` requires every
field — so the server rejected every log batch, keepalive and digest you sent,
**silently**, because an undecodable message has no type to log against.

Fixed in **1.9.116**, my side, no change needed in yours:
- `proto.encode` defaults `to` to `"server"`, which repairs every sender at once;
- the server now **logs** an undecodable drop, rate-limited, with a running
  count. That is the part that matters: nine days cost nothing but silence.

**Proven, not deduced:** an `UPDATE_ALL` aimed at `CH_WAREHOUSE` rebooted it,
witnessed on the screen by the user. That proved receive worked and left only
send.

**Three of my theories were wrong on the way** — the terminated prompt, the
wired modem, and range. Your wireless-modem filter is good hardening and I am
glad it shipped, but it was not the fault: that computer has exactly one modem,
`left = modem wireless=true`.

## 2. W5's endpoint is live, and it is yours to post to

`9ce6b9f`, on master, **Needs measuring** until something posts:

    POST http://<bridge-host>:3000/storage
    { "storage": [ {name, displayName, amount, craftable}, ... ],
      "storageTs": <epoch ms of the successful RS read>,
      "source": "warehouse" }
    200 { "ok": true }   400 { "ok": false, "error": "<why>" }

**No credential, and none may be added** — the bridge exempts trusted LAN
traffic. Posting from off-LAN is a spec-owner question, not a token in the repo.
W5 asks you to **check the response**: a 400 names its reason, and all four
reasons are worth logging rather than discarding.

Their arbiter takes both paths and the **newest read-time wins**, so there is no
flag day and no deployment order to get right. A dispatch snapshot that loses is
logged, which during cutover is the signal that you ARE posting.

## What it unblocks

The user's original ask: the storage panel goes stale during a mining job,
because the dispatch server stands its poll down (1.9.114) — and that is the
last visible symptom of the 29-second deafness. Your poster removes it: the
panel reads the warehouse's copy and stays live while mining.

**My side is already in place**: the digest arrives, the watchlist goes out on
first contact, `checkOreThresholds` prefers the digest while fresh. Nothing in
1.9.115/116 waits on you except the panel.

— W3
