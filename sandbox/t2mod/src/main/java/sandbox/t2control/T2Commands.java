package sandbox.t2control;

import java.util.LinkedHashMap;
import java.util.Map;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;

/** The /t2 command family (spec section 6). Every reply is one line of JSON. */
public final class T2Commands {
    private T2Commands() {}

    public static void register(CommandDispatcher<CommandSourceStack> d) {
        d.register(Commands.literal("t2").requires(s -> s.hasPermission(2))
            .then(Commands.literal("radio").then(Commands.literal("log")
                .then(Commands.argument("state", StringArgumentType.word()).executes(c -> toggle(c.getSource(), "radio", StringArgumentType.getString(c, "state"))))))
            .then(Commands.literal("events").then(Commands.literal("log")
                .then(Commands.argument("state", StringArgumentType.word()).executes(c -> toggle(c.getSource(), "events", StringArgumentType.getString(c, "state"))))))
            .then(Commands.literal("status").executes(c -> reply(c.getSource(), Logs.status()))));
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
