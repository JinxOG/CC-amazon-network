"""The ack-loss replay on real Minecraft (the first payoff of the control mod and of the testing spec): the fleet parked at the base,
no job, for 4 game hours at 10x, on whatever code the run was pinned to (--pin). The simulator reproduced 9.08% parked loss on the
code from before the private channel (23f5a97^) and 0.03% on current master (calibration note); the report's ack_loss section is
the real-Minecraft answer for the same code."""
NAME = "ack_loss_parked"


def steps(ctx):
    ctx.tickrate(200)
    ctx.wait_game(4 * 3600)
    ctx.expect(len(ctx.state()["turtles"]) >= 10, "the fleet stayed registered (%d turtles)" % len(ctx.state()["turtles"]))
