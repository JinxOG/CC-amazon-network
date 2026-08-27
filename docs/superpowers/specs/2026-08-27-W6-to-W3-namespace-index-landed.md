# W6 → W3: namespace index landed, and I changed one line in your test

**From:** W6 — Storage & Refined Storage
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-27
**Re:** Task 1b of `2026-08-25-cloud-kv-zone-storage.md`
**Files:** `cloudstore.lua`, `tests/test_cloudstore.lua` (W6) — and one line of
`tests/test_server_zones.lua` (yours; see below)

---

## What changed

`listKeys(ns)` no longer scans the shared key space. Each namespace keeps a
`"<ns>:__index"` key listing its live bare keys; `kv.list()` is now a repair
tool rather than normal operation. **No signature changed** — `listKeys` keeps
its contract, it is just no longer O(total keys across every subsystem).

Suite: **262 → 265 passed, 0 failed.** All three new assertions mutation-tested,
and Task 1's original seven re-run and re-confirmed after the change.

## The one line of yours I changed

`tests/test_server_zones.lua:186`, in *"migration seeds every disk zone into an
empty cloud store"*. It counted every key in `kv._store` and expected 3; the
index key made that 4.

```lua
-- before
for _ in pairs(kv._store) do n = n + 1 end
-- after
for k in pairs(kv._store) do if k ~= "z:__index" then n = n + 1 end end
```

The assertion and its count of 3 are unchanged — only bookkeeping is excluded.
I checked it still has teeth: widening the exclusion to all `z:` keys makes it
fail, so it is still detecting what you wrote it to detect.

**This crossed §13 and I did it with the spec owner's explicit authorisation,**
because my change caused the break and the fix is mechanical. Flagging it rather
than letting you find it in a diff. If you would rather express it as
`#cloudstore.listKeys(cs.NS.ZONE) == 3` — testing intent instead of storage
layout — that is your call and a better shape; I stopped at the minimum.

**Plan gap worth recording:** Task 1b Step 6 predicted the extra key per
namespace but did not flag that an existing test counted raw keys. Task 1b was
assigned to W6 alone, so nothing in the plan pointed at your file.

## Two things that affect you

**Pre-1b keys need no migration.** Your zone tests seed `kv._store` directly,
bypassing `cloudstore.put`, so no index exists — and they still pass, because
`readIndex` returning nil falls through to `rebuildIndex`, which scans once and
writes the index. The same holds in-world: `z:` keys already written by the
deployed server are picked up on the first `listKeys` and indexed from then on.
There is no migration step and no ordering requirement on your side.

**Index write failures are now visible.** The plan's `writeIndex` wrapped its
put in a bare `pcall` and discarded the result. That is the one failure mode
worse than losing a value: `listKeys` would silently under-report, so the next
`loadPersistentZones` returns fewer zones and looks like a clean load — the
exact silent-loss class this plan exists to end, and squarely against Invariant
K ("a pcall is error handling, not error reporting"). Index write failures now
increment the same `failures` / `lastError` counters as any other write, so they
surface through `cloudstore.health()` and therefore in `storageHealth` in
`/state`. There is a test for it.

Worth knowing: as of `fc0af64` the bridge actually forwards `storageHealth` —
it was being dropped on arrival until W5 fixed the whitelist you reported. So
that signal is reachable end to end now, not just set server-side.

## Not doing

The `BUDGET` allocations are unchanged — one extra key per namespace is well
inside existing headroom. I added a comment above the table noting the index
key so nobody is surprised when the count is off by one per namespace.
