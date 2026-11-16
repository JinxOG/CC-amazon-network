# Android OS: direction (2026-11-16)

The user's direction, given to the head engineer on 2026-11-16. It is **parked until the shakeout is done**. It is not yet a spec. It supersedes the earlier plan to run androids inside Turtle OS through `android_base.lua` and `android_main.lua`.

## What the user wants

- **Android OS is a separate stack.** It has its own repo and its own section of the dashboard, and does not run Turtle OS. The head engineer runs both and is the link between them.
- **Androids take standing jobs** that the user sets and can track:
  - stand by on the turtle fleet and fill in where they can (for example building, while every turtle mines);
  - wait at a driver depot (Uber-style haulage);
  - run a mob farm;
  - look after and rescue turtles.
- **Built for coding agents.** Androids should be easy to automate, test and simulate, and should give quick, honest answers. A coding agent should be able to reach into a live android's body when needed.
  - Why: Turtle OS made little progress until deep logs and simulators existed.
  - The approach is both at once: plain programs run the routine, and an AI steps in when an android is stuck.
- **Reuse what fits, don't redo it.** Turtle OS gets trimmed back to its core: the user feels it has grown bloated and larger in scope than intended.

## Three projects, one at a time

1. Trimming and recentring Turtle OS.
2. The new features in the CC Androids fork (another agent is working on the fork now).
3. Android OS itself.

## Suggestions for the mod fork, each from a Turtle OS lesson

1. **The mod logs every action, its result and its reason** to a file or a web endpoint. Turtle OS's logs come from the turtle's own program and lose lines.
2. **A live control door into each android:** read its position, inventory and recent events, and give it actions directly, without radio. The test server's T2 control mod already does this for turtles.
3. **The game reports position and facing.** "Boxed in, facing unknown" is a whole class of Turtle OS failure that comes from turtles working this out for themselves.
4. **Faults as built-in commands:** radio loss, a power cut, a restart, and unloading the android's area. That way recovery is tested on purpose.
5. **Save and replay:** snapshot an android and its surroundings, then re-run the same moment and get the same result.
6. **The mod describes its own commands,** so a coding agent can ask what exists instead of guessing.
7. **Scenario tests with real pass/fail:** "in this world, do this, expect that within N seconds". The check must be able to fail, and a pass must look different from "nothing happened".
8. **Programs load from a folder on the server,** so a change is live at once, with no GitHub cache delay and no over-the-air update traps.
9. **Fast loops (walking, driving, guarding) run inside the mod,** so the Lua program stays short.

The earlier API wish list is in `docs/android-mod-wishlist.md`.

## What Android OS would take from Turtle OS

- **Take:** the dashboard and bridge, the message format, the log pipeline, the job board, and the simulator and test-server method.
- **Leave behind:** GPS facing checks, the movement journal, chunk-loader pairing and the fuel ender chest. The mod makes them unnecessary.
