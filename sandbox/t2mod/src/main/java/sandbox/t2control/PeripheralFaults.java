package sandbox.t2control;

import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Peripheral faults (spec section 6): for a peripheral TYPE (the name a program finds it by, such as rsBridge), calls can be made slow
 * (a fixed extra time before the call runs) or can fail (the call raises an error). Each rule has a duration in game ticks and ends by
 * itself. Pure logic (no Minecraft types) so it can be unit tested.
 */
public final class PeripheralFaults {
    public static final PeripheralFaults INSTANCE = new PeripheralFaults();

    public enum Kind { NONE, STALL, FAIL }

    public static final class Decision {
        public final Kind kind;
        public final int extraMs;
        Decision(Kind kind, int extraMs) { this.kind = kind; this.extraMs = extraMs; }
        static final Decision NONE = new Decision(Kind.NONE, 0);
    }

    private static final class Rule {
        final String type; final boolean fail; final int extraMs; final long expires;
        Rule(String type, boolean fail, int extraMs, long expires) { this.type = type; this.fail = fail; this.extraMs = extraMs; this.expires = expires; }
    }

    private final CopyOnWriteArrayList<Rule> rules = new CopyOnWriteArrayList<>();
    private final AtomicLong stalled = new AtomicLong();
    private final AtomicLong failed = new AtomicLong();

    public void addStall(String type, int extraMs, long nowTick, int durationSeconds) {
        rules.add(new Rule(type, false, extraMs, nowTick + durationSeconds * 20L));
    }

    public void addFail(String type, long nowTick, int durationSeconds) {
        rules.add(new Rule(type, true, 0, nowTick + durationSeconds * 20L));
    }

    public void clear() { rules.clear(); }

    public int activeRules(long nowTick) {
        int n = 0;
        for (Rule r : rules) if (r.expires > nowTick) n++;
        return n;
    }

    /** Failing wins over stalling when both are active for the type. Counts what it decides, so a run can show the fault was hit. */
    public Decision decide(String type, long nowTick) {
        Decision stall = null;
        for (Rule r : rules) {
            if (r.expires <= nowTick || !r.type.equals(type)) continue;
            if (r.fail) {
                failed.incrementAndGet();
                return new Decision(Kind.FAIL, 0);
            }
            if (stall == null) stall = new Decision(Kind.STALL, r.extraMs);
        }
        if (stall != null) {
            stalled.incrementAndGet();
            return stall;
        }
        return Decision.NONE;
    }

    public long stalledCalls() { return stalled.get(); }

    public long failedCalls() { return failed.get(); }
}
