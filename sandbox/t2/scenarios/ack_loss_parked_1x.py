"""The ack-loss replay at the speed that counts: 1x, the fleet parked at the base, no job, 4 game hours (= 4 real hours), on whatever
code the run was pinned or installed to. Ack loss is timing behaviour, so the testing spec (6.8) wants it measured at 1x; the 10x runs
(ack-old2, ack-new) under-state it because the fleet's real-clock traffic per game tick drops about N-fold."""
NAME = "ack_loss_parked_1x"


def steps(ctx):
    ctx.wait_game(4 * 3600)
    ctx.expect(len(ctx.state()["turtles"]) >= 10, "the fleet stayed registered (%d turtles)" % len(ctx.state()["turtles"]))
