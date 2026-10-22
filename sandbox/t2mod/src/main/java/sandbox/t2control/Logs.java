package sandbox.t2control;

import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

import com.google.gson.Gson;
import com.google.gson.JsonObject;

/**
 * The three logs under <run>/t2control/ (spec section 7): radio.jsonl, events.jsonl, interventions.jsonl. Radio and event
 * logging are off until switched on; interventions are always recorded. Lines are formatted here and written by LogWriter.
 */
public final class Logs {
    public static final int BODY_LIMIT = 2048;
    private static final Gson GSON = new Gson();

    public static final AtomicBoolean RADIO_ON = new AtomicBoolean(false);
    /** Also log the radio attempts that did not reach a program (out of range, channel closed): large, off by default. */
    public static final AtomicBoolean RADIO_ALL = new AtomicBoolean(false);
    public static final AtomicBoolean EVENTS_ON = new AtomicBoolean(false);

    private static volatile LogWriter radio;
    private static volatile LogWriter events;
    private static volatile LogWriter interventions;
    private static volatile Path dir;
    private static volatile TickSource ticks = () -> -1L;

    /** The current game tick (the mod supplies the server's; unit tests supply their own). */
    public interface TickSource { long now(); }

    private Logs() {}

    public static synchronized void open(Path directory, TickSource tickSource) {
        close();
        dir = directory;
        ticks = tickSource;
        radio = new LogWriter(directory.resolve("radio.jsonl"), 200_000);
        events = new LogWriter(directory.resolve("events.jsonl"), 400_000);
        interventions = new LogWriter(directory.resolve("interventions.jsonl"), 10_000);
    }

    public static synchronized void close() {
        for (LogWriter w : new LogWriter[] {radio, events, interventions}) if (w != null) w.close();
        radio = events = interventions = null;
    }

    public static LogWriter radioWriter() { return radio; }

    public static LogWriter eventsWriter() { return events; }

    public static LogWriter interventionsWriter() { return interventions; }

    /** A body as text, cut at BODY_LIMIT characters; the full length is kept by the caller. */
    public static String clip(String s) {
        return s.length() <= BODY_LIMIT ? s : s.substring(0, BODY_LIMIT);
    }

    private static JsonObject base() {
        JsonObject o = new JsonObject();
        o.addProperty("tick", ticks.now());
        o.addProperty("utc", System.currentTimeMillis());
        return o;
    }

    /** One delivery attempt. outcome: delivered / lost / delayed:<ms> / dropped_receiver_gone. */
    public static void radio(double fromX, double fromY, double fromZ, String sender, int toComputer, int channel, int replyChannel,
                             double distance, String body, String outcome) {
        LogWriter w = radio;
        if (w == null || !RADIO_ON.get()) return;
        JsonObject o = base();
        o.addProperty("from", sender);
        o.addProperty("from_pos", Math.round(fromX) + "," + Math.round(fromY) + "," + Math.round(fromZ));
        o.addProperty("to", toComputer);
        o.addProperty("channel", channel);
        o.addProperty("reply_channel", replyChannel);
        o.addProperty("distance", Math.round(distance * 10) / 10.0);
        o.addProperty("body", clip(body));
        o.addProperty("body_length", body.length());
        o.addProperty("outcome", outcome);
        w.offer(GSON.toJson(o));
    }

    /** One event queued to one computer. */
    public static void event(int computer, String name, String args) {
        LogWriter w = events;
        if (w == null || !EVENTS_ON.get()) return;
        JsonObject o = base();
        o.addProperty("computer", computer);
        o.addProperty("event", name);
        o.addProperty("args", clip(args));
        w.offer(GSON.toJson(o));
    }

    /** A /t2 command that changed something. */
    public static void intervention(String verb, Map<String, ?> args, String result) {
        LogWriter w = interventions;
        if (w == null) return;
        JsonObject o = base();
        o.addProperty("verb", verb);
        o.add("args", GSON.toJsonTree(args));
        o.addProperty("result", result);
        w.offer(GSON.toJson(o));
    }

    public static String status() {
        JsonObject o = new JsonObject();
        o.addProperty("radio_log", RADIO_ON.get());
        o.addProperty("radio_log_all", RADIO_ALL.get());
        o.addProperty("events_log", EVENTS_ON.get());
        for (Object[] row : new Object[][] {{"radio", radio}, {"events", events}, {"interventions", interventions}}) {
            LogWriter w = (LogWriter) row[1];
            JsonObject s = new JsonObject();
            if (w != null) {
                s.addProperty("written", w.written());
                s.addProperty("dropped", w.dropped());
                s.addProperty("queued", w.queued());
            }
            o.add((String) row[0], s);
        }
        o.addProperty("dir", dir == null ? "" : dir.toString());
        return GSON.toJson(o);
    }
}
