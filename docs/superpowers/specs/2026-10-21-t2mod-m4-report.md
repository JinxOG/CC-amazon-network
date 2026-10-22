# T2 control mod - M4 report: turtle move and turtle save / restore

Date: 2026-10-21. Forge 1.20.1-47.4.10 (matches live), CC:Tweaked 1.120.2, Advanced Peripherals 0.7.46r, mod t2control 0.1.0.

## What M4 adds

- `/t2 turtle move <computer id> <x> <y> <z> [n|e|s|w]` (Python `turtle_move(id, x, y, z, facing)`): moves the turtle through the call a turtle uses to move itself (`ITurtleAccess.teleportTo`), then turns it to the requested facing. The computer is not restarted and knows where it is. This replaces the older `/clone ... replace move` route (`teleport`), which left the turtle with a stale idea of its place and could not set a facing; `teleport` stays for runs without the mod.
- `/t2 turtle save <computer id> <name>` and `/t2 turtle restore <name>` (Python `turtle_save`, `turtle_restore`): one atomic call each. A save keeps the turtle's block data (inventory, fuel, upgrades, facing, label), its position, and its computer's disk folder, under `<run>/t2control/saves/<name>/`. A restore shuts the computer down, moves the turtle back to where it was saved, empties the inventory and loads the saved data, puts the disk folder back, and turns the computer on.

## Proof, both ways (run m4-a, `prove_mod.py m4`, 9 of 9)

| claim | evidence |
|---|---|
| the probe turtle runs | 11 uptime rows, no block seen facing north |
| move keeps the computer on | after a move the dump shows the new place, the computer is on, and its uptime (os.clock) kept counting 11.1 s -> 19.1 s over 19 rows with no restart |
| facing is as asked | facing east: `detect` sees the stone east of the new place |
| every facing | moves n, w, s, e, w between two spots: the mod reports the facing back each time, and `detect` is true exactly where a stone stands (east of one spot, west of the other) and false elsewhere |
| bad input | a bad facing and an unknown computer id are answered with an error, nothing moves |
| restore returns the saved state | after changing fuel (777 -> 111), clearing slot 3, filling slot 5, rewriting a file on the disk and moving the turtle, a restore brings back fuel 777, the original position, slot 3 (9 cobblestone), an empty slot 5 and the original file, and the computer is on |
| the program runs after restore | the probe's uptime rows continue from a fresh boot |
| restore of an unknown name | answered with an error |
| interventions logged | every move, the save and the restore |

## Something found while proving it

Loading saved turtle data does NOT empty a slot that the saved data leaves out (the same behaviour as the NBT `data remove` note in the T2 notes): the first restore brought fuel, position, slot 3 and the file back but left the dirt in slot 5. The restore now empties the inventory first. A proof that only checked "what was saved is back" would have passed; the proof also checks that what was added afterwards is gone.

## Not covered

Only turtles (not pocket computers or plain computers), only loaded computers, and only blocks that are free at the target (the call refuses a target that is not air). A turtle that is mid-action when it is moved or restored is not specially handled; the scenario decides when.
