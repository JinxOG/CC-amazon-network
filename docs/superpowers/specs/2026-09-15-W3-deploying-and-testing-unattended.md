# Deploying to the fleet and testing it, unattended

**W3 — Fleet & Dispatch, 2026-09-15.** Written at the user's request as the
standard for every engineer.

This is the loop I actually run, and the mistakes that shaped each part of it.
Every war story below is mine and most are from the last twenty-four hours.

The through-line: **almost everything that has gone wrong here was a check that
could not fail.** Not broken fleet code — broken *checking*. Plan accordingly.

---

## 0. The loop

    1  merge only what is green          tests + mutants, on a rebased branch
    2  confirm the fleet is idle         and mean it
    3  deploy                            POST /self-update
    4  confirm the deploy LANDED         poll every node's version, not the server's
    5  dispatch a job on fresh ground    verify the geometry before you send it
    6  watch to completion               re-arm the watcher; windows expire
    7  run the gate                      one command, evidence counts, no memory
    8  only then, merge the next release

Never run 3 and 5 close together in either order. A deploy reboots every turtle;
a job in flight when that happens is a stranded miner.

---

## 1. Merging: green means both

Tests pass **and** every planted mutant dies. A suite that passes against
deliberately broken code is decoration.

> **War story.** The mutation harness once certified mutants against an
> already-red baseline — every mutant "died" because the test was failing
> anyway. It now refuses to run unless the baseline is green, and it caught me
> again today: I added a test with a bad anchor, and the harness stopped rather
> than reporting 121 kills over a broken suite.

**Attribute each mutant to the test that guards it.** When I planted "the loop
stops counting its own turns", three tests went red but the one I had named
stayed green — because with no turns counted the report correctly returns
nothing. If the harness had accepted any red, that test would have been credited
with coverage it did not have.

**Rebase before you merge, and rerun.** Branches drift. Renumber the version in
the same commit, and check no other branch claims it: I had two branches both
claiming 1.9.103 and only noticed because I looked.

---

## 2. "Fleet idle" means all of it

    turtles: all IDLE     active jobs: 0

Not "the job I know about finished". Read `/state` and check both. A dispatch
creates **one job per miner** — cancelling one of a pair leaves the other
running, and it will be the one that strands.

---

## 3. Deploying

    POST /self-update    -- git pull on the server, then UPDATE_ALL to the fleet

The response carries the git output. **Read it.** `Updating 606de4a..fba2529` is
a real pull; anything else means the fleet is about to run code you did not
expect, or the same code you already had.

### The trap that cost eleven hours of fleet downtime

**The updater running an OTA is the PREVIOUS version, with the PREVIOUS file
list.** I shipped a new module and the first `require` of it in one release. The
updater that ran had never heard of the file, did not fetch it, and every turtle
rebooted into `module 'logship' not found`. Fifteen turtles, all dead, recovered
only by typing `updater` at each one by hand.

**So: a new module and its first use are two releases.** Release one teaches the
updater about the file. Release two uses it. The same shape applies to anything
where the server and the turtles must agree — which is why the per-turtle channel
change is three releases, and why reversing the order takes the fleet deaf.

A new *message type* is exempt: an older turtle routes an unknown type to its
inbox and ignores it, so either order degrades to "nothing happens".

---

## 4. Confirming the deploy landed

**`proto.VERSION` does not certify the server.** It is a constant in a file; it
tells you what the source says, not what is running.

Poll until every node reports the new version:

    all 15 on 1.9.105  ->  DEPLOY LANDED

Not fourteen. A straggler is a turtle that will re-register into a fleet talking
a protocol it does not have.

> **War story.** I once diagnosed live behaviour against a version number and was
> wrong about which code was running. Check bytes, or check what every node
> reports — never the number you expect to see.

---

## 5. Dispatching

Full mechanics are in the mail to the spec owner. The parts that bite:

- **`ORDER_MINE`, never `DISPATCH_MINE`.** The wrong type logs a WARN server-side
  and the bridge still returns `{"ok":true}`. I waited on a job that had never
  been created, and the only evidence was a line I was not reading.
- **Never send a coordinate that is an exact multiple of 32.** The zone collapses
  on that axis — half the sectors, and one miner instead of two, silently.
- **Check overlap against the RUNNING job too.** A live zone is keyed by job id
  in `/state.mineZones`, not by `zone:`. My first overlap check only looked at
  historical zones and proposed ground that was being mined at that moment.

`tools/next_zone.py` does all three and prints its rejections with reasons.

---

## 6. Watching

Watchers have a finite window. **Re-arm them.** A job takes six hours; a watcher
does not. If a notification says "window ended, job still running", that is not a
result.

Watch for *faults*, not just progress: ERROR lines, FAILED jobs, ACK timeouts,
recalls. Stop early on any of them rather than discovering it in the gate.

---

## 7. The gate: one command, never from memory

    python tools/gate_check.py <since-ISO> [job_id ...]

> **War story.** I certified a job "clean, no new fault" having checked errors,
> failures, ACK timeouts and recalls — and not repeated sectors, which that job
> contained. The verdict was defensible; the word "clean" was not. A gate you
> reassemble from memory each time is a gate that drifts.

**Every check prints its evidence count.** "0 repeated sectors" out of 2 sector
completions is not the same claim as out of 95, and a check that found nothing
because it *looked* at nothing must never render as a pass.

---

## 8. Rollback

Reverting is the same operation as deploying, so it costs the same care:

1. Fleet idle (all of it).
2. `git revert` the release commit and push. **Do not force-push** — other
   engineers are on this master.
3. `POST /self-update`, then poll until every node reports the old version.
4. Say what broke, in the same session, as `info` mail. A rollback nobody hears
   about is a version mystery for the next person.

If the fleet is already bricked, rollback will not reach it: the turtles are not
running an updater that can hear you. That is a hand-recovery at each turtle, and
it is the reason §3's two-release rule is not negotiable.

---

## 9. What I would tell a new engineer not to do

Each of these is a mistake I made, most of them today.

**Do not trust `{"ok":true}`.** The bridge returns it for commands the server
rejects. Check the server's own log for the line your command should have made.

**Do not build the instrument before reading the code path.** I built a
per-turtle reboot command to test the stale-sector fix. The entire path is behind
`if midJob`, and `midJob` is the turtle reporting that its job coroutine is
alive — which a rebooted turtle's is not. The test could never have reached the
code. Had the evidence condition been only "no repeat happened", it would have
"passed" and closed a card having proved nothing.

**Do not validate a detector by checking it fires on known-bad data.** I
"validated" a repeated-sector detector by confirming it fired on jobs traced as
containing the bug. Firing *somewhere inside* such a job is not firing *on* the
bug. Checked properly, zero of sixteen of those repeats had the reconnection the
mechanism requires. I had published a baseline built on it and had to retract it.

**Do not report an absence as a pass.** "No fault occurred" and "the check never
ran" look identical from the outside. Make every check state what it examined.

**Do not poll a log endpoint with `order=head` and a limit.** It returns the
*oldest* matching lines. Once the day has more matches than the limit, new ones
never appear. My probe reported zero disconnects across 45 minutes while 25 were
happening. Always pass `since=`.

**Do not group log lines without sorting them.** They do not come back in
timestamp order even when you ask for head order. Unsorted grouping produced
episodes with negative durations.

**Do not assume a query covers the window.** My gate derived the day from its
`since` argument and queried one day, so it went blind when a job crossed
midnight and reported "no completion line" for a job that completed fine.

**Do not let a rule live only in a comment.** `turtle_base` states that every
message type the control loop handles must be in `CTRL_TYPES`, or it lands in a
queue nothing drains. That rule had already cost silently-declined work, and
nothing tested it. A comment cannot fail a build.

**Do not close a broadcast.** Ten minutes into the new mailbox I closed a memo
addressed to six engineers and emptied five inboxes for a protocol none of them
had read. I only noticed because I checked someone *else's* inbox afterwards.

---

## 10. The one habit worth copying

Before running a check, ask: **what would make this fail?** If there is no
answer, the check is decoration and a passing result from it means nothing.

The corollary, which is the only reason any of this week's findings survived:
when a result looks *too clean*, verify it independently before reporting it.
Every retraction above began with a number I was pleased to see.

— W3
