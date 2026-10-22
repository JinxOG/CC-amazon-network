package sandbox.t2control;

import java.util.LinkedHashMap;
import java.util.Map;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.DoubleArgumentType;
import com.mojang.brigadier.arguments.IntegerArgumentType;
import com.mojang.brigadier.arguments.StringArgumentType;
import com.mojang.brigadier.builder.ArgumentBuilder;
import com.mojang.brigadier.context.CommandContext;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;

/** The /t2 command family (spec section 6). Every reply is one line of JSON. */
public final class T2Commands {
    private T2Commands() {}

    public static void register(CommandDispatcher<CommandSourceStack> d) {
        d.register(Commands.literal("t2").requires(s -> s.hasPermission(2))
            .then(Commands.literal("radio")
                .then(Commands.literal("log")
                    .then(Commands.argument("state", StringArgumentType.word()).executes(c -> toggle(c.getSource(), "radio", StringArgumentType.getString(c, "state")))))
                .then(Commands.literal("loss")
                    .then(Commands.argument("rate", DoubleArgumentType.doubleArg(0, 1))
                        .then(withTail(Commands.argument("duration", IntegerArgumentType.integer(1, 86400)), T2Commands::loss))))
                .then(Commands.literal("latency")
                    .then(Commands.argument("min_ms", IntegerArgumentType.integer(0, 60000))
                        .then(Commands.argument("max_ms", IntegerArgumentType.integer(0, 60000))
                            .then(withTail(Commands.argument("duration", IntegerArgumentType.integer(1, 86400)), T2Commands::latency)))))
                .then(Commands.literal("clear").executes(c -> clear(c.getSource()))))
            .then(Commands.literal("chunk")
                .then(Commands.literal("list").executes(c -> reply(c.getSource(), Chunks.list())))
                .then(Commands.literal("status").executes(c -> reply(c.getSource(), "{\"released\":" + ChunkFaults.INSTANCE.activeCount(T2Control.currentTick())
                        + ",\"refusals\":" + Chunks.refusals() + "}")))
                .then(Commands.literal("probe")
                    .then(Commands.argument("chunk_x", IntegerArgumentType.integer())
                        .then(Commands.argument("chunk_z", IntegerArgumentType.integer())
                            .executes(c -> reply(c.getSource(), Chunks.probe(c.getSource().getServer(),
                                    IntegerArgumentType.getInteger(c, "chunk_x"), IntegerArgumentType.getInteger(c, "chunk_z")))))))
                .then(Commands.literal("tickets")
                    .then(Commands.argument("chunk_x", IntegerArgumentType.integer())
                        .then(Commands.argument("chunk_z", IntegerArgumentType.integer())
                            .executes(c -> reply(c.getSource(), Chunks.tickets(c.getSource().getServer(),
                                    IntegerArgumentType.getInteger(c, "chunk_x"), IntegerArgumentType.getInteger(c, "chunk_z")))))))
                .then(Commands.literal("unload")
                    .then(Commands.literal("area")
                        .then(Commands.argument("x1", IntegerArgumentType.integer())
                            .then(Commands.argument("z1", IntegerArgumentType.integer())
                                .then(Commands.argument("x2", IntegerArgumentType.integer())
                                    .then(Commands.argument("z2", IntegerArgumentType.integer())
                                        .then(Commands.argument("duration", IntegerArgumentType.integer(1, 86400))
                                            .executes(c -> reply(c.getSource(), Chunks.unloadArea(c.getSource().getServer(),
                                                    IntegerArgumentType.getInteger(c, "x1"), IntegerArgumentType.getInteger(c, "z1"),
                                                    IntegerArgumentType.getInteger(c, "x2"), IntegerArgumentType.getInteger(c, "z2"),
                                                    IntegerArgumentType.getInteger(c, "duration"), T2Control.currentTick())))))))))
                    .then(Commands.argument("computer", IntegerArgumentType.integer(0))
                        .then(Commands.argument("duration", IntegerArgumentType.integer(1, 86400))
                            .executes(c -> reply(c.getSource(), Chunks.unload(IntegerArgumentType.getInteger(c, "computer"),
                                    IntegerArgumentType.getInteger(c, "duration"), T2Control.currentTick())))))))
            .then(Commands.literal("turtle")
                .then(Commands.literal("move")
                    .then(Commands.argument("computer", IntegerArgumentType.integer(0))
                        .then(Commands.argument("x", IntegerArgumentType.integer())
                            .then(Commands.argument("y", IntegerArgumentType.integer())
                                .then(withTail(Commands.argument("z", IntegerArgumentType.integer()), T2Commands::turtleMove))))))
                .then(Commands.literal("save")
                    .then(Commands.argument("computer", IntegerArgumentType.integer(0))
                        .then(Commands.argument("name", StringArgumentType.word())
                            .executes(c -> reply(c.getSource(), Turtles.save(c.getSource().getServer(), net.minecraftforge.fml.loading.FMLPaths.GAMEDIR.get(),
                                    IntegerArgumentType.getInteger(c, "computer"), StringArgumentType.getString(c, "name")))))))
                .then(Commands.literal("restore")
                    .then(Commands.argument("name", StringArgumentType.word())
                        .executes(c -> reply(c.getSource(), Turtles.restore(c.getSource().getServer(), net.minecraftforge.fml.loading.FMLPaths.GAMEDIR.get(),
                                StringArgumentType.getString(c, "name"), T2Control.currentTick()))))))
            .then(Commands.literal("events").then(Commands.literal("log")
                .then(Commands.argument("state", StringArgumentType.word()).executes(c -> toggle(c.getSource(), "events", StringArgumentType.getString(c, "state"))))))
            .then(Commands.literal("status").executes(c -> reply(c.getSource(), Logs.status()))));
    }

    /** A command node that runs with no options, or with a free-text tail such as "channel 5 to 12 seed 3". */
    private static ArgumentBuilder<CommandSourceStack, ?> withTail(ArgumentBuilder<CommandSourceStack, ?> node,
                                                                    java.util.function.BiFunction<CommandContext<CommandSourceStack>, String, Integer> run) {
        return node.executes(c -> run.apply(c, ""))
            .then(Commands.argument("options", StringArgumentType.greedyString()).executes(c -> run.apply(c, StringArgumentType.getString(c, "options"))));
    }

    /** Reads "channel N", "to N", "seed N" pairs; returns null and says why in err[0] when something is not understood. */
    static Map<String, Long> parseOptions(String tail, String[] err) {
        Map<String, Long> out = new LinkedHashMap<>();
        String[] t = tail.trim().isEmpty() ? new String[0] : tail.trim().split("\\s+");
        for (int i = 0; i < t.length; i += 2) {
            String key = t[i];
            if (!(key.equals("channel") || key.equals("to") || key.equals("seed")) || i + 1 >= t.length) {
                err[0] = "options are: channel <n>, to <computer id>, seed <n>";
                return null;
            }
            try {
                out.put(key, Long.parseLong(t[i + 1]));
            } catch (NumberFormatException e) {
                err[0] = key + " needs a number";
                return null;
            }
        }
        return out;
    }

    private static int turtleMove(CommandContext<CommandSourceStack> c, String tail) {
        String facing = tail.trim().isEmpty() ? null : tail.trim();
        return reply(c.getSource(), Turtles.move(c.getSource().getServer(), IntegerArgumentType.getInteger(c, "computer"),
                IntegerArgumentType.getInteger(c, "x"), IntegerArgumentType.getInteger(c, "y"), IntegerArgumentType.getInteger(c, "z"), facing, T2Control.currentTick()));
    }

    private static int loss(CommandContext<CommandSourceStack> c, String tail) {
        String[] err = new String[1];
        Map<String, Long> o = parseOptions(tail, err);
        if (o == null) return reply(c.getSource(), "{\"error\":\"" + err[0] + "\"}");
        double rate = DoubleArgumentType.getDouble(c, "rate");
        int duration = IntegerArgumentType.getInteger(c, "duration");
        long now = T2Control.currentTick();
        int channel = o.containsKey("channel") ? o.get("channel").intValue() : Faults.ANY;
        int to = o.containsKey("to") ? o.get("to").intValue() : Faults.ANY;
        long seed = Faults.INSTANCE.addLoss(rate, now, duration, channel, to, o.get("seed"));
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("rate", rate); args.put("duration_s", duration); args.put("channel", channel); args.put("to", to); args.put("seed", seed);
        args.put("start_tick", now); args.put("expires_tick", now + duration * 20L);
        String result = "{\"ok\":true,\"seed\":" + seed + ",\"expires_tick\":" + (now + duration * 20L) + "}";
        Logs.intervention("radio_loss", args, result);
        return reply(c.getSource(), result);
    }

    private static int latency(CommandContext<CommandSourceStack> c, String tail) {
        String[] err = new String[1];
        Map<String, Long> o = parseOptions(tail, err);
        if (o == null || o.containsKey("to")) return reply(c.getSource(), "{\"error\":\"" + (o == null ? err[0] : "latency takes channel and seed only") + "\"}");
        int min = IntegerArgumentType.getInteger(c, "min_ms");
        int max = IntegerArgumentType.getInteger(c, "max_ms");
        int duration = IntegerArgumentType.getInteger(c, "duration");
        long now = T2Control.currentTick();
        int channel = o.containsKey("channel") ? o.get("channel").intValue() : Faults.ANY;
        long seed = Faults.INSTANCE.addLatency(min, max, now, duration, channel, o.get("seed"));
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("min_ms", min); args.put("max_ms", max); args.put("duration_s", duration); args.put("channel", channel); args.put("seed", seed);
        args.put("start_tick", now); args.put("expires_tick", now + duration * 20L);
        String result = "{\"ok\":true,\"seed\":" + seed + ",\"expires_tick\":" + (now + duration * 20L) + "}";
        Logs.intervention("radio_latency", args, result);
        return reply(c.getSource(), result);
    }

    private static int clear(CommandSourceStack src) {
        Faults.INSTANCE.clear();
        Logs.intervention("radio_clear", new LinkedHashMap<>(), "{\"ok\":true}");
        return reply(src, "{\"ok\":true}");
    }

    private static int toggle(CommandSourceStack src, String which, String state) {
        boolean on;
        if ("on".equals(state) || ("radio".equals(which) && "all".equals(state))) on = true;
        else if ("off".equals(state)) on = false;
        else return reply(src, "{\"error\":\"state must be on or off (radio also: all)\"}");
        if (which.equals("radio")) {
            Logs.RADIO_ON.set(on);
            Logs.RADIO_ALL.set(on && "all".equals(state));
        } else {
            Logs.EVENTS_ON.set(on);
        }
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("state", state);
        String result = "{\"ok\":true,\"" + which + "_log\":\"" + state + "\"}";
        Logs.intervention(which + "_log", args, result);
        return reply(src, result);
    }

    private static int reply(CommandSourceStack src, String json) {
        src.sendSuccess(() -> Component.literal(json), false);
        return 1;
    }
}
