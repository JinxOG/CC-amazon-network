# Concept — a GPS host that reports in

- **Status: IDEA, back burner.** Not designed, not approved for building, not
  in the cleanup. Recorded so it is not lost. When it is picked up it gets a
  proper design pass first.
- **Raised:** 2026-10-05, by the user.
- **Likely owner when picked up:** W3 (fleet). Unowned until then.

## Why

The four GPS host computers run CC's built-in `gps host`
(`gps_host.lua` → `shell.run("gps", "host", X, Y, Z)`). That program is not
what failed on 2026-09-17: **all four computers stopped at once**, nothing
reported it, and the only symptom was every turtle refusing to move for want
of a fix. Cause never found; the user restarted them by hand.

The hosts are the one part of the fleet's infrastructure that is invisible.
The idea is to make them visible, resilient and updatable.

## Hard constraint

**Keep the standard GPS protocol.** Turtles keep calling `gps.locate()`;
nothing on the turtle side changes. Everything below is added around
`gps host`, never instead of its replies.

## Candidate features, by value

1. **Check in with the server** — a heartbeat, so the dashboard can show
   "GPS host 3 down" before any turtle fails.
2. **Verify its own coordinates at boot** by locating against the other
   hosts. A mistyped coordinate gives turtles a *wrong* position, which is
   worse than none: no GPS stops a turtle, wrong GPS sends it confidently
   into the wrong place.
3. **Report restarts with a boot id.** Four restarts at once means the server
   or the chunk restarted — the clue missing on 09-17.
4. **Restart itself on error** rather than sitting dead.
5. **Hosts watch each other** and report a neighbour that stops answering.
6. **Support more than four hosts.** With exactly four, losing one can break
   fixes for the whole fleet; a fifth and sixth make one failure free.
7. **Store coordinates outside the program**, so it can be updated without
   re-typing positions. The repo copy carries placeholder coordinates
   (0, 255, 0); each live host was hand-edited.
8. **Over-the-air updates, one host at a time — never all four together**, so
   GPS never drops during an update.
9. **Count requests** — pings per minute and by whom, to spot a lost turtle
   locating over and over.
10. **Logs into the fleet log**, timestamped alongside turtles and server.

**Server-side companion:** raise an alarm when several turtles fail to locate
within a minute. That catches a host that cannot report its own death (an
unloaded chunk, a server restart), which no program on the host can.

## What it cannot fix

If the chunk unloads or the server restarts and the hosts do not come back, no
code on them helps. The check-in and the server-side alarm turn that from
hours of silence into minutes.

## If it is ever pulled forward

Items 1, 3 and the server-side alarm are *measure and repair* of a fault that
has already stopped the fleet, so they would fit a cleanup-style freeze. The
rest are features.
