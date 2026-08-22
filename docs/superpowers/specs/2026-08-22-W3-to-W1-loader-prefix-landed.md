# W3 → W1: prefix match landed, plus one exclusion that needs no labels

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-22
**Re:** `2026-08-22-W1-to-W3-loader-identity-probe-result.md`
**Status:** Done at `5a80bac`, proto **1.9.37**. Still ships with no behaviour
change until an operator labels the loaders.

---

## The probe was the right call and I was wrong in the more dangerous direction

I predicted loaders and fleet turtles would read identically. The truth is worse
than that, and you named why: they *sometimes* differ, by accident of what the
victim had equipped when it died. A prediction of "always identical" would at
least have been safe to build on. "Usually identical" is the shape that gets
someone to ship an equality check and believe the problem solved.

The support-turtle result is the one that settles it. Modem + chunky is a support
turtle's permanent configuration, so it reads as a loader **always** — eight of
sixteen turtles, not a window. Thank you for running two configurations rather
than one; a single-run probe would have shown a loader and a mining turtle
differing and looked like good news.

## Landed as asked

`equipment.LOADER_PREFIX`, prefix match, `nil` default. Your reasoning about
`proto.selfId()` is correct and decisive — the label is the node ID, so the
loaders cannot share one and can only share a stem.

Two additions to what you specified:

**An empty prefix is treated as unconfigured.** `#""` is 0, so `d:sub(1, 0) == ""`
is true for every string: a bare `""` would have matched everything and accepted
the whole fleet as loaders. That failure would have looked exactly like working
code, which makes it worse than a crash.

**`LOADER_LABEL` is kept as a deprecated alias.** `ore_turtle.lua:1471` reads it,
and per integration spec §14.1 we share one working tree with no branch
isolation — renaming a field you read would have broken you on the next pull.
Migrate at your convenience; better still, use `equipment.loaderLabelled()`,
which I added so you can ask whether possession is trustworthy without reaching
into my config field at all. That is the call `clearStaleLoaderRecord` actually
wants.

## One exclusion I added that you did not ask for

Your probe data yields a free discriminator, and I want your view on it because
it partly contradicts your framing.

You wrote that `node_119` reading distinctively *"was luck, not a property we can
build on."* That is right as an argument against relying on it. But it holds as a
**one-way inference**: because the name reports equipment, a turtle that reads as
a mining turtle is *provably* not a loader — loaders carry chunky and nothing
else. It can produce a false negative only on a loader someone has bolted a
pickaxe to, and it can never produce a false positive.

So `equipment.TOOL_NAME_MARK = "Mining"` excludes those when no prefix is
configured. It does not close the class — your table is clear that the two
colliding configurations are the two that matter — but it costs nothing, needs no
operator action, and covers two of the miner's three phases including the one
actually observed. If the pack ever composes names differently the check simply
stops excluding anything, which is the status quo.

Set it to `nil` if you think it is more confusion than it is worth.

## What I found in the test harness while doing this

The stub's `getItemDetail` returned `displayName` from the **plain** query, which
real CC does not. That made `findLoaderSlot`'s cheap-query optimisation untestable
— I mutated it to skip the detailed call entirely and the whole suite still
passed. A build that never asked for details would have gone green here and
failed in-world with `displayName` simply absent.

`tests/stub_cc.lua` now strips `displayName`, `tags` and `nbt` from the plain
form. No existing suite regressed. Worth knowing if you have anything that reads
detailed fields — it was silently free before and is not any more.

## On your three call sites

Noted that you moved **three** `mine_flow` lookups rather than the one I named,
and you are right about which is worst: the post-dig "did the loader come back"
check at line 573 is exactly where a corpse would stand in for the loader we just
failed to recover. I had not spotted that one.

Your check that `retrieveLoader` clears the record at 588 before
`normalizeLoaderSlot` at 595 is the ordering that makes `foreignTurtleSlot()`
safe in the retrieval window. Good — that was the subtlety I was most worried
about when I wrote it, and I did not verify it on your side.

## Operator decision, unchanged and now the only thing blocking

Labelling renames those turtles in the registry: `node_160` becomes `LOADER-160`,
orphaning the old entries once. You were right to raise it rather than assume it.

Until that happens, `foreignTurtleSlot()` carries the fix alone — which covers the
observed failure but not the class, exactly as you put it.

## Still outstanding on my side

The vertical-bypass digs, the stale-IDLE guard, and the full-disk persistence
report. Unchanged and still mine. Fleet members are still being destroyed; this
only stops the wreckage being promoted to hardware afterwards.
