"""W1 card "A miner digs its own equipment up with nowhere to put it", LAYER 2 for the SCANNER half.

WHY A SECOND SCENARIO AND NOT JUST w1_loader_no_room. The guard itself is shared
(mine_flow.makeRoomForEquipment), and the loader scenario exercises it. What is
NOT shared is everything the scanner half added in 1.9.168: reclaimScanner's
refusal, the arrival check (mine_flow.ensureEquipmentAboard), the suck-back, and
the scanner being a ledger kind. The fault this card exists for was a scanner
lost and a NEEDS HANDS that could never clear, so the scanner is what has to be
watched.

THE FAULT, measured 2026-11-24. node_453 (shakeout-payload-h) and node_411
(shakeout-payload-i) each raised `slot_1_must_hold_the_geo_scanner` and never
cleared, so each was benched for the rest of its run -- 2 of 2 runs. Both had
"only 1 free mining slot(s)" logged, both were killed exactly on a scan level,
and neither printed any `[SCAN]` line at boot, which is how we know the
placement record was already empty. The pickup dug with no free-slot count, a
dig with no room still returns TRUE, so scannerClear() wiped the record and the
scanner was gone.

HOW THE PACK IS MADE UNBANKABLE. Filled with `enderstorage:ender_chest`, a
GENUINE hardware name: equipment.isHardwareItem accepts it, and ore_turtle's
`shouldDump` filter keeps -- rather than banks -- anything whose name is in
protectedItemNames, where the ore chest's name already is because the miner
carries one. So the dump banks nothing, no payload slot can be dropped
(makeRoomForEquipment refuses hardware), and the scanner pickup meets the one
case where it must REFUSE rather than dig.

THE STAGING IS ARTIFICIAL AND THE PATH IS REAL. No miner carries nine ender
chests. What this exercises is `freeSlots() == 0` with nothing droppable at the
instant of the pickup -- reachable for real whenever a dump cannot bank -- and
the refusal, the kept record and the scanner still standing are real behaviour.
Said plainly rather than dressed up as a field reproduction.

WHAT IT ASSERTS, and what it only records:
  - ASSERTS the staging took (an unverified staging measures nothing -- the trap
    that void-ed run w1-skip-c).
  - ASSERTS the miner reached a scan level, so the pickup was actually reached.
    Without that anchor every check below passes for want of evidence.
  - ASSERTS no `slot_1_must_hold_the_geo_scanner` appears. That is the card.
  - ASSERTS the guard spoke: with an all-hardware pack it must print the refusal
    rather than dig. A run that gets here without it means the pack was not
    actually full at the instant of the dig.
  - RECORDS the suck-back and lost lines, because with the guard working they
    should not fire at all, and asserting their absence would pass trivially.

1x. The reboot-free path is the point: this fault needs no reboot, only a full
pack, which is also the thing the restart burst was wrongly credited with.
"""
NAME = "w1_scanner_no_room"

ZONE = {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1}

MINE_LUA_FIRST, MINE_LUA_LAST = 5, 13
FILL_ITEM = "enderstorage:ender_chest"

NEEDS_HANDS = "slot_1_must_hold_the_geo_scanner"
SCAN_REFUSED = "REFUSING to dig the scanner up"
SCAN_DROPPED = "No slot free for the scanner"
SCAN_SUCKED = "recovered it off the ground behind us"
SCAN_LOST = "neither aboard nor behind us"
SCANNING = "phase SCANNING"
LEFT_PLACED = "scanner left placed"


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control

    miners = sorted(int(n.replace("node_", "")) for n, t in (ctx.state().get("turtles") or {}).items()
                    if isinstance(t, dict) and (t.get("role") or "").upper() == "MINER"
                    and n.replace("node_", "").isdigit())
    ctx.expect(bool(miners), "found miners to stage (%s)" % miners)
    if not miners:
        return
    cid = miners[0]
    node = "node_%d" % cid
    ctx.note("staging %s; miners present: %s" % (node, miners))

    # ---- STAGE, AND VERIFY IT TOOK ----
    staged = 0
    for lua in range(MINE_LUA_FIRST, MINE_LUA_LAST + 1):
        try:
            got = c.set_slot(cid, lua - 1, FILL_ITEM, 1)      # NBT slots are 0-based
        except Exception as e:  # noqa: BLE001 - a refused write is a finding
            ctx.note("slot %d (NBT %d) refused: %s" % (lua, lua - 1, e))
            continue
        if FILL_ITEM.split(":")[-1] in str(got):
            staged += 1
        else:
            ctx.note("slot %d (NBT %d) read back as %s" % (lua, lua - 1, got))
    want = MINE_LUA_LAST - MINE_LUA_FIRST + 1
    ctx.note("payload slots staged: %d of %d" % (staged, want))
    ctx.expect(staged == want,
               "every mining slot of %s holds an UNDROPPABLE hardware item before the job "
               "(%d of %d, read back from the world) -- with the pack not actually full and "
               "unbankable the guard cannot fire and this run would prove nothing"
               % (node, staged, want))
    if staged == 0:
        return

    base = {k: len(ctx.log_lines(k)) for k in
            (NEEDS_HANDS, SCAN_REFUSED, SCAN_DROPPED, SCAN_SUCKED, SCAN_LOST, SCANNING, LEFT_PLACED)}
    ctx.dispatch("ORDER_MINE", ZONE)

    # ---- ANCHOR: it reached a scan level, so the pickup was reached ----
    scanned = ctx.wait_until(lambda: len(ctx.log_lines(SCANNING)) > base[SCANNING], 2 * 3600)
    ctx.expect(bool(scanned),
               "a miner reached a scan level (%d new SCANNING lines) -- the scanner pickup "
               "happens once per level, so without this nothing below is about this card"
               % (len(ctx.log_lines(SCANNING)) - base[SCANNING]))
    if not scanned:
        ctx.note("INCONCLUSIVE: never reached a scan level, so the pickup never ran")
        return

    ctx.wait_game(600)

    def since(k):
        return ctx.log_lines(k)[base[k]:]

    hands, refused = since(NEEDS_HANDS), since(SCAN_REFUSED)
    dropped, sucked, lost = since(SCAN_DROPPED), since(SCAN_SUCKED), since(SCAN_LOST)
    placed_left = since(LEFT_PLACED)
    for name, rows in (("NEEDS HANDS", hands), ("refusal", refused), ("made room", dropped),
                       ("sucked back", sucked), ("LOST", lost), ("left placed", placed_left)):
        ctx.note("%s: %d line(s)%s" % (name, len(rows), (" | " + rows[0].strip()[-120:]) if rows else ""))

    # ---- THE CARD ----
    ctx.expect(not hands,
               "no miner was benched for a missing geo scanner (%d '%s' lines) -- this is the "
               "fault the card is about, and it ended 2 of 2 shakeout runs for the miner it hit"
               % (len(hands), NEEDS_HANDS))

    # ---- AND THE GUARD ACTUALLY SPOKE, which only this staging can show ----
    ctx.expect(bool(refused),
               "the guard REFUSED to dig the scanner up (%d '%s' lines) -- with every payload "
               "slot holding hardware there is no room to be made, so a run that reaches here "
               "WITHOUT this line means the pack was not full at the instant of the dig and the "
               "absence above proves nothing" % (len(refused), SCAN_REFUSED))

    # ---- AND THE SCANNER WAS LEFT RECOVERABLE, not thrown away ----
    ctx.expect(bool(placed_left),
               "and the scanner was left placed with its record kept (%d lines) -- 'placed and "
               "recorded' is what the refusal trades for 'on the floor and forgotten'"
               % len(placed_left))

    # RECORDED, not asserted: with the guard working these should never fire, so
    # asserting their absence would pass trivially and tell nobody anything.
    ctx.note("suck-back fired %d time(s) and 'neither aboard nor behind' %d time(s); with the "
             "guard working both should be 0, and a non-zero suck-back means the pack filled "
             "between the check and the dig" % (len(sucked), len(lost)))
