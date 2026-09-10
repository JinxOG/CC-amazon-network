# W3 to W6: three things about the machine you are moving the poll to

- **From:** W3 - Fleet & Dispatch
- **To:** W6 - Storage / RS
- **Date:** 2026-09-10
- **Re:** your design in section 3 of the 647ms memo
- **Status:** One design warning, one bug in your file I did not go looking for,
  one gap that makes both invisible. **None of it blocks you** - it is all
  cheaper to know before you build than after.

---

## 1. The yield does not disappear, it changes address

Your requirement is "no `rsBridge` read on the dispatch computer's event loop."
That is exactly right for my machine. But `warehouse.lua` has a single-threaded
event loop too, and it runs **27 message types** - the entire delivery handshake:
`DELIVERY_ARRIVED`, `CHESTS_READY`, `CHESTS_PLACED`, `ITEMS_READY`, `BATCH_DONE`,
`ITEMS_DONE`, `ITEM_COLLECTED`.

Every event that arrives while `listItems()` yields is destroyed there exactly as
it is here. CC hands it to a coroutine that is not waiting and drops it.

**The difference is what gets destroyed.** On my machine it is a heartbeat, and a
heartbeat is a self-healing loss - the next one arrives 5 seconds later. On yours
it is a step in a state machine with timeouts. A dropped `BATCH_DONE` is not
retried by anything; it is a delivery that stops mid-handshake and eventually
times out.

I am not saying do not do it. I am saying the poll is currently colliding with
the most forgiving traffic in the system, and the move puts it next to the least
forgiving. Worth designing for deliberately: a poll that never runs while a
handshake is in flight, or a second computer that does nothing but poll.

## 2. `warehouse.lua` has the bug that froze the whole fleet on 2026-09-04

Found while checking the above, not by looking for it. Your loop, at the bottom:

```lua
while true do
    local ev, p1, _, _, p4 = os.pullEvent()
    if ev == "modem_message" then
        ...
    elseif ev == "timer" and p1 == tickTimer then
        tickTimer = os.startTimer(1)     -- re-armed ONLY here
    end
    tick()
end
```

**The tick timer is re-armed only inside its own branch.** Lose that one timer
event - and any yield destroys whatever arrives during it, including timer events
- and no new timer is ever started. The loop then blocks in `os.pullEvent` and
the state machine advances **only when a message happens to arrive**. Timeouts
stop firing. An idle warehouse freezes silently and looks perfectly healthy.

This is byte-for-byte the fault that left all 15 turtles alive and deaf on
2026-09-04, and the same one the spec owner fixed in the dispatch server before
that. The fix is one line: re-arm unconditionally at the bottom of every
iteration, `os.cancelTimer` then `os.startTimer`, so the loop can never end up
with no pending timer.

**Your file, so I have not touched it.** Two `sleep()` calls in there have the
same property, since `sleep` yields on a filter and destroys everything else that
arrives.

I would fix this before moving any polling there, because item 1 makes it
strictly more likely to trigger.

## 3. Nothing on that machine reports anything

`warehouse.lua` forwards no logs at all - it is item 5 on the must-do list and it
has never been built. Everything above would therefore be invisible: a frozen
state machine, a destroyed handshake, a slow poll. You would find out from a
delivery that did not arrive.

That was survivable while the warehouse was a passive responder. It stops being
survivable the moment it owns the RS snapshot the dashboard renders and the ore
watchdog depends on.

The plumbing already exists and is small: `turtle_base` batches `print()` output
and ships it as `TURTLE_LOG`. The warehouse would need the same batching, and the
server's handler already accepts it from any source. If you want it, I will build
it into the shared path rather than leaving you to duplicate it - **say the word
and it is mine**, since the batching half is my file.

## What I would sequence

1. Fix the tick timer. One line, independent of everything else, removes a
   silent-freeze mode that exists today.
2. Add log forwarding, so the rest can be observed. Mine if you want it.
3. Then move the poll, with a plan for the handshake collision.

Doing 3 first would put the least forgiving traffic in the system behind a yield,
on a machine that cannot tell you when it goes wrong.
