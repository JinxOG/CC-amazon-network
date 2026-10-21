"""The fleet boots in real Minecraft and registers with the local bridge; five minutes at 1x, then a power cycle verb."""
NAME = "smoke_boot"


def steps(ctx):
    ctx.expect(len(ctx.state()["turtles"]) >= 14, "at least 14 turtles registered with the bridge (%d)" % len(ctx.state()["turtles"]))
    ctx.wait_real(60)
    ctx.control.shutdown([143])
    ctx.wait_real(20)
    ctx.control.turn_on([143])
    ctx.expect(ctx.wait_until(lambda: ctx.control.computers().get(143, {}).get("on"), 60), "#143 came back on after a shutdown and turn_on")
    ctx.wait_real(30)
    ctx.expect(len(ctx.log_lines("Registered node_")) >= 14, "the server logged at least 14 'Registered node_' lines")
