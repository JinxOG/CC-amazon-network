# Replay both ETA models against job_0086/0087's real sector data.
#
# One zone, four sectors, two miners (node_119 and node_138), from the server's
# own completion lines on 2026-09-24:
#
#   (1760,-3104)  4420 ore   done 17:43:45  node_119
#   (1792,-3136)  5110 ore   done 18:06:38  node_138
#   (1760,-3136)  4512 ore   done 20:59:26  node_138
#   (1792,-3104)  3775 ore   done 21:00:58  node_119
#   then a rescan + re-mine pass, 0 ore, and the jobs complete 21:26:15 / 21:28:22.
#
# Found ore is taken as the ore actually mined, which is the survey's own view
# minus whatever was left behind -- so this replay if anything prices sectors
# slightly LOW, in the same direction as the error being measured.

OVERHEAD, PER_ORE, RESCAN, EMPTY = 462, 2.196, 252, 270

ORE = {"A": 4420, "B": 5110, "C": 4512, "D": 3775}
COMPLETE_MIN = 21 * 60 + 26          # job_0086 complete 21:26


def old_model(pending, miners):
    secs = sum(OVERHEAD + ORE[s] * PER_ORE for s in pending)
    secs += 4 * RESCAN + 4 * EMPTY   # the passes still to come
    return secs / miners / 60


def new_model(pending, held, miners):
    # held: {sector: ore already out of it}
    queued = sum(OVERHEAD + ORE[s] * PER_ORE for s in pending)
    queued += 4 * RESCAN + 4 * EMPTY
    secs, longest = [], 0
    for s, mined in held.items():
        left = max(0, ORE[s] - mined) * PER_ORE
        if mined <= 0:
            left += OVERHEAD
        secs.append(left)
        longest = max(longest, left)
    total = queued + sum(secs)
    return max(total / max(miners, len(held)), longest) / 60


def row(label, at_min, old, new):
    actual = COMPLETE_MIN - at_min
    print(f"{label:>8} | {old:8.0f} | {new:8.0f} | {actual:8.0f} | "
          f"{old - actual:+7.0f} | {new - actual:+7.0f}")


print("   clock |  1.9.117 |  1.9.118 |   actual |  .117 err |  .118 err")
print("---------+----------+----------+----------+-----------+----------")

# 15:04 -- mine phase just started. 375 ore out of the zone, so both miners are
# a few minutes into the two sectors they were handed; the other two are queued.
row("15:04", 15 * 60 + 4,
    old_model(["C", "D"], 2),
    new_model(["C", "D"], {"A": 190, "B": 185}, 2))

# 17:14 -- 7757 ore out, nothing finished yet. Same two sectors in hand.
row("17:14", 17 * 60 + 14,
    old_model(["C", "D"], 2),
    new_model(["C", "D"], {"A": 3900, "B": 3857}, 2))

# 17:44 -- A finished at 17:43:45 (4420) so node_119 has just taken C and
# reported nothing out of it yet; node_138 is near the end of B.
row("17:44", 17 * 60 + 44,
    old_model(["D"], 2),
    new_model(["D"], {"B": 4684, "C": 0}, 2))
