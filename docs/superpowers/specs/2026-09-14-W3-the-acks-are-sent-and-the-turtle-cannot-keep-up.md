# W3: the ACKs are sent. The turtle cannot keep up with its own mailbox.

**Date:** 2026-09-14
**Bears on:** the exit gate. This is a mechanism for fault 2 (single-turtle ACK
loss), with a number attached and a fix that is not a guess.

## Measured: the loss is on the reply path

The server stamps `lastSeen` on every heartbeat it processes, and `/state`
publishes it. So for each "Server unreachable — 20 s since last ACK, 3 beats
attempted", we can ask whether the server's clock for that turtle kept moving
during the window the turtle spent believing it was alone.

The probe ran to completion: **nineteen disconnects, nineteen of nineteen the
same**. The first ten, in full:

    18:27:37 node_103   lastSeen +13398 ms over a 15001 ms window
    18:27:39 node_102   lastSeen +10003 ms over a 10001 ms window
    18:29:21 node_142   lastSeen +17556 ms over a 15002 ms window
    18:29:22 node_143   lastSeen +17556 ms over a 15002 ms window
    18:29:21 node_109   lastSeen +17556 ms over a 15002 ms window
    18:32:45 node_104   lastSeen +16984 ms over a 20002 ms window
    18:34:50 node_94    lastSeen +14041 ms over a 15001 ms window
    18:36:03 node_104   lastSeen +13238 ms over a 15001 ms window
    18:36:05 node_103   lastSeen +20077 ms over a 20001 ms window
    18:37:04 node_141   lastSeen +13434 ms over a 15000 ms window

The clock advances at essentially wallclock rate — the server was hearing that
turtle the entire time it was being declared unreachable.

**The obvious objection, checked and dead:** a turtle re-registers the instant it
gives up, and that also stamps `lastSeen`. Cross-referencing the server's
`Re-registered` lines against all nineteen windows — there were 20 re-registrations
in the probe period, so the check had something to find: **0 of 19** fell inside a
window. The advance is from heartbeats and nothing else.

The window also ends strictly *at* the warning, not after it. An earlier version
of this probe ran to three seconds past the warning and would have returned
"server heard it" for every case regardless of truth — a verdict that could not
have failed. That version's results were discarded, not published.

So: **turtle → server is fine. server → turtle is where messages die.**

## Measured: proximity is not the mechanism

The turtles carry `computercraft:wireless_modem_advanced` — the ender modem,
effectively unlimited range. Every turtle therefore hears every transmission
regardless of where it stands. **There is no such thing as local radio
congestion in this fleet**, and the dock-cluster congestion theory from this
morning's memo is dead. I was wrong to lead with it.

The base-versus-field split is real but it is not about location. It is about
what a turtle is *doing*, and turtles are only ever idle at base. The two were
confounded from the start.

## Measured: the receiver is oversubscribed

Every private reply from the server — every `HEARTBEAT_ACK` — goes out on a
single shared channel:

    sendTo()  ->  proto.send(modem, proto.CH_PRIVATE, msg)
    turtle    ->  opens CH_BROADCAST, CH_PRIVATE, CH_LOCAL
                  and keeps a message only if msg.to == its own id

So **each turtle receives all fifteen turtles' private traffic and throws away
fourteen fifteenths of it.** With fifteen turtles heartbeating every ~5 s that is
**3.0 inbound messages per second, per turtle, floor** — before broadcasts,
loader beacons, or any turtle-to-turtle coordination.

Against that, the control loop handles **exactly one event per iteration**
(`local event, p1, p2, p3, p4 = os.pullEvent()`), and the turtles report their
own loop rate in every warning. Across **666 witness samples today**:

| loop turns per second | |
|---|---|
| minimum | 0.56 |
| **median** | **1.77** |
| maximum | 7.86 |

Median worst pause inside a window: **4.4 s**, max 5.2 s — during which roughly
thirteen messages arrive with nothing draining them.

**1.77 processed against 3.0 arriving** — a deficit close to two to one.

**A selection bias in that figure, and it is mine to own.** The loop-turn count
is emitted *only* inside the unreachable warning (`turtle_base.lua` 2167, 2189).
There is no healthy-period sample anywhere in the logs. So 1.77/s is measured
exclusively during the windows in which ACKs were being lost, and the honest
claim is the narrower one:

> **When a turtle is losing ACKs, its loop is running at roughly 1.77 turns per
> second against at least 3.0 messages per second arriving.**

I cannot yet say the loop is *always* too slow, and my first draft of this memo
said exactly that. If the loop normally runs at 6/s and only sags to 1.77/s in
these windows, the slowdown is a symptom of something else and the channel
arithmetic is a red herring.

**The measurement that decides it is cheap:** emit the same turn count and worst
pause on a healthy heartbeat — say one beat in twenty — so there is a baseline to
compare against. Without it this section is a correlation with a plausible story
attached, and it should not be treated as more than that. It does not weaken the
direction result above, which stands on its own at 19 of 19.

## Inferred, and labelled as such

A queue that is filled faster than it is drained overflows, and CC drops events
when it does. A turtle's own ACK is then no likelier to survive than the fourteen
it did not want. That is consistent with everything above — the server looking
healthy, the reply direction being the lossy one, the loss being steady rather
than bursty, and three in a row going missing often enough to trip MAX_MISSED
several times an hour.

It also fits the idle-versus-working split, though less cleanly, and I want to be
honest that this is the weakest link in the chain: a working turtle spends its
time inside `turtle.forward`, `turtle.dig` and similar, each of which yields on a
filter and *discards* non-matching events as it goes. Discarding is not the same
as overflowing, but it does keep the queue short. A parked turtle neither drains
quickly nor discards, so it is the one that fills up. I have not measured queue
depth directly — CC exposes no API for it — so this last step is reasoning, not
measurement.

## The fix worth doing

**Subject to the baseline measurement above**, give each turtle its own private
channel. `CH_PRIVATE` is one number; make it
a base plus the turtle's own index, so a turtle receives only traffic addressed
to it. Inbound drops from ~3.0/s to ~0.2/s, a fifteen-fold cut, and the loop's
1.77/s stops being a deficit and becomes eleven times the required rate. The
`msg.to == _self.id` filter stays as a belt-and-braces check.

This is cheaper and more certain than trying to make the loop drain faster, and
it scales: the current design gets quadratically worse with fleet size, which is
why this was invisible at five turtles and is biting at fifteen.

**It must roll out in two phases, or it takes the fleet down.** The server must
not start transmitting on the new channel before every turtle is listening on it
— that is the same shape as the OTA trap that cost us an outage on 1.9.94.

1. Turtles open **both** the shared channel and their own. Server unchanged.
   Deploy, confirm all fifteen on the new version.
2. Server switches `sendTo` to the per-turtle channel. Deploy.
3. Later, turtles stop opening the shared one.

## What I got wrong today, on the record

I led this morning with cluster radio congestion as the live hypothesis. The
modem type rules it out and I should have checked that before writing it up
rather than after. The geography measurement it rested on is still correct —
536 of 539 at the dock — but the explanation I hung on it was not.

— W3
