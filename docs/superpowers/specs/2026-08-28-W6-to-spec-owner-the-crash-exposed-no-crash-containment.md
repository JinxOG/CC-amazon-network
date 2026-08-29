# W6 → spec owner: the retry loop stays, and the mod bug exposed something worse

**From:** W6 — Storage & Refined Storage
**To:** Spec owner
**Date:** 2026-08-28
**Re:** `2026-08-28-spec-owner-to-W6-the-rs-import-crash-was-a-mod-bug.md`

---

## 1. The retry loop is not a workaround for the mod bug — it stays

You asked me to check the history rather than delete on suspicion. I did:

```
git log -L '/^local function clearEnderChest/,/^end$/:warehouse.lua'
→ 4834fe6  2026-06-04  "clearEnderChest retry, ..."
```

`4834fe6` is **BUG#16 of the 2026-06-04 codebase audit**, landed **22 days before**
the crash first appeared on 26 June. Its stated reason — "RS storage being full or
an un-insertable item can leave residue that contaminates the next batch" — is a
different failure and is still real.

So it is not dead weight. It is kept, and now has a comment saying why, so the
next person to wonder does not have to re-derive it from git.

## 2. What happened to an item mid-import — §4's row holds, but barely

Items were **not** lost. The ender chest is persistent in-world, so anything
mid-transfer stayed in it, and the startup sweep re-imports on the next boot.
§4's *"deliveries stall; nothing is lost"* is accurate for the items.

**It was not accurate for the warehouse.** `rsBridge.importItem` was unprotected,
so the throw left `clearEnderChest`, left `main`, and reached the bottom of the
file — which printed `CRASH:` and **exited**. The program did not stall. It
disappeared, and stayed gone until a human noticed deliveries had stopped.

That is the useful half of your message, and it is the part worth fixing:
`central_server` reboots on crash, `warehouse.lua` did not. One peripheral fault
took out the whole layer with no restart and no record.

## 3. Fixed

- **All four `rsBridge` calls now go through `rsCall`**, which pcalls, logs, and
  returns `nil, err`. The mod bug is fixed upstream, but the exposure is not
  specific to `importItem` — an unloaded RS network, a bridge broken by a player,
  or the next mod regression arrive identically.
- **Crash restart parity with `central_server`**: persist to `wh_crash.log`,
  reboot after 5s, and replay the last crash into the log at startup. Rebooting
  rather than re-calling `main()` is deliberate — it re-wraps every peripheral
  handle, which is what is most likely stale after a fault.
- **A test seam and the first tests this file has ever had.** `warehouse.lua`
  had zero coverage because requiring it entered `main()` and never returned.
  Six assertions, all mutation-tested, including one that restores the exact
  unprotected `importItem` call and confirms the suite goes red.

Suite: **273 → 280 passed, 0 failed.**

One thing the mutation pass caught: my "unknown method" guard was behaviourally
redundant — `pcall` already fails on a nil function — so the assertion could not
fail. Its real value is the message naming the method instead of "attempt to call
a nil value", so that is what the test now asserts.

## 4. Not verified, and I want to be clear about it

**I have not confirmed RS import works in-world.** That needs a real item pushed
through the warehouse path, which means dispatching a delivery — a side-effecting
action in your world that I am not going to take unasked, and the bridge now
returns 401 on `/state` so I cannot watch it either.

What I can say: the harness proves a *throwing* import no longer kills the
warehouse. Whether 0.7.46r actually fixed the throw is an in-world check, and
it's one command plus watching a delivery complete. Say the word and I'll walk
through it.

## 5. Recipe Registry vs §11.7 — my opinion, with the caveat first

**Caveat:** I have not verified UnlimitedPeripheralWorks' Recipe Registry API. I
am not going to design against remembered API details — that is how I spent two
rounds today debugging a server that was not running the code I thought it was.
What follows is conditional on the registry being able to resolve a recipe tree
on demand.

**It should augment §11.7, not replace `missing[]`.** They answer different
questions:

- The **registry** answers *"what does this recipe need?"* — static, side-effect
  free, answerable before committing to anything.
- **`missing[]`** answers *"what could RS not actually finish?"* — dynamic, and
  it accounts for current stock, machine availability, and whatever else the
  network is busy doing.

A BOM computed purely from the registry would be right about ingredients and
wrong about feasibility. So:

- Add a **`RECIPE_QUERY` / `RECIPE_RESULT`** pair to §11.7 for side-effect-free
  BOM expansion. That directly serves §9.1's planning phase and P3
  ("infeasibility is discovered at plan time, never at build time") — today the
  only way to discover a shortfall is to *start* a craft, which is exactly the
  wrong time.
- **Keep `CRAFT_STATUS.missing[]` unchanged** as execution truth. It remains how
  a craft RS cannot finish becomes a mining or harvest deficit.

The gain is real: the planner stops having to speculatively fire `craftItem` to
learn what it lacks. That also removes a live hazard — a speculative craft that
partially succeeds consumes materials for a project that may never be approved.

**Prerequisite before any of this is specced:** confirm the registry can expand a
tree, not just a single recipe, and whether it reflects the modpack's actual
recipes or only vanilla. If it cannot recurse, the BOM still has to come from RS
and the contract stays as it is.

## Deployment

`warehouse.lua` only — `install warehouse` or an OTA, then reboot **the warehouse
computer**. Nothing else changed. I did not bump `proto.VERSION`: it was already
moved to 1.9.60 by another stream in the shared tree while I was working, and
adding a second bump on top would only obscure whose change is deployed.
