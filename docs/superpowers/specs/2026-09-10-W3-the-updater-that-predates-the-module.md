# I bricked the fleet, and the manifest test passed the whole time

**2026-09-10 · from W3 (Fleet & Dispatch) · for every workstream that ships a file**

---

## What happened

At 1.9.93 I moved the log outbox out of `turtle_base.lua` into a new
`logship.lua`, and added `require("logship")` to `turtle_base.lua`. I added
`logship.lua` to `updater.lua`'s `COMMON` list and to every `install.lua`
profile in the same commit, and I wrote a test asserting that every role is sent
every module its files require.

The operator deployed it. Every turtle came back from the reboot at a shell
prompt:

```
module 'logship' not found
  no file '/rom/modules/main/logship.lua'
  ...
Line 73
local logship = require("logship")
```

Fifteen of them, in the world.

## Why the test did not catch it

Because the test was right and the deploy was still wrong.

**The updater doing the work is always the previous version.** It is already
loaded and running from the previous file list when it downloads the new one. So
at 1.9.93 each turtle's updater:

1. downloaded `COMMON` — from the **old** list, which had no `logship.lua`;
2. downloaded the **new** `turtle_base.lua`, which requires it;
3. verified everything it had set out to write (all present, all correct);
4. rebooted into a `turtle_base` requiring a file nobody had told it to fetch.

Every step reported success, because every step *did* succeed. The manifest was
self-consistent. **A manifest cannot make the running program read it.**

That is the whole lesson, and it generalises past this incident:

> A new shared module and the first `require` of it **cannot ship in the same
> release**, unless the deployer itself notices it has been replaced.

## The fix

`updater.lua` now reads its own bytes before downloading `COMMON`, and if that
run replaced `updater.lua` with different content, it restarts — **before it
touches a single role file**. It terminates after exactly one relaunch, because
the second pass reads the file before downloading it and finds them identical.

`update.lua` has always done this; it re-downloads `install.lua` before running
it. This is the same idea for the over-the-air path, which never had it.

## What I got wrong twice

I wrote the guard first, then two source-ordering assertions for it. **Mutation
killed both.**

- `if false and selfAfter ~= selfBefore` leaves every matched string in place.
- Moving the `readSelf()` that produces `selfAfter` below the role loop leaves
  the comparison text exactly where it was, while making the value `nil`.

A test that matches the *position of text* cannot see whether a branch is live
or whether its values are in scope. That is the fifth source assertion this week
to pass against broken code, and this path is too expensive to guard with one.

So `updater.lua` is now loaded into a fake CC computer — in-memory disk,
in-memory GitHub, `os.reboot` as a sentinel — and **run**. The first test is the
incident itself: old updater on disk, new everything on the remote, assert
`logship.lua` ends up on disk.

Then mutation killed *that* too. My ordering test withheld the role files from
pass one and expected it to fail on them — but an updater that checks itself
*after* the role loop relaunches anyway, and the second pass cleans up, so the
outcome is identical while the bug is fully present. What actually separates the
two is **which files each pass asks for**. The transport is now instrumented and
the assertion is that pass one never fetches `turtle_base.lua`.

## Recovery, if you hit this before 1.9.94 is everywhere

The turtles are not bricked, they are at a shell prompt, and the **new**
`updater.lua` is already on their disk — it came down as part of `COMMON`. At
each prompt:

```
updater
```

It reads `role.txt`, downloads the new list including `logship.lua`, verifies,
and reboots.

## What I did not do

I did not make `require("logship")` a `pcall`. It would have turned "the fleet
does not boot" into "the fleet boots with logging silently off", and a state
whose healthy appearance is indistinguishable from its broken one is the thing
I have argued against four times this week. The deployer was broken, not the
require. With the fix, a module now provably arrives before the file that needs
it — tested by running the real updater, not by reading it.

## What this asks of you

Nothing, if you are on 1.9.94 or later. Before then: if you add a `require` on a
new file, ship the file in one release and the `require` in the next.

**Tests:** 344 → 349. Five new, four of them driving the real `updater.lua`.
28 mutants in `tests/mutate_logship.py`, all killed by their intended test — two
of which existed only because they caught tests of mine that could not fail.

— W3
