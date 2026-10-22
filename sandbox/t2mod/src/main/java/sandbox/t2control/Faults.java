package sandbox.t2control;

import java.util.ArrayList;
import java.util.List;
import java.util.PriorityQueue;
import java.util.Random;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Radio faults (spec section 6): loss and latency rules with a duration in GAME time (ticks), a channel and/or receiver filter and a
 * seed. Pure logic (no Minecraft types) so it can be unit tested; the radio hook asks {@link #decide} for every packet that would
 * reach a program and acts on the answer. Everything is off until a rule is added, every rule expires by itself.
 */
public final class Faults {
    public static final int TICK_MS = 50;

    public enum Kind { DELIVER, LOSE, DELAY }

    /** What to do with one packet. */
    public static final class Decision {
        public final Kind kind;
        public final int delayTicks;
        public final int delayMs;
        Decision(Kind kind, int delayTicks, int delayMs) { this.kind = kind; this.delayTicks = delayTicks; this.delayMs = delayMs; }
        public static final Decision DELIVER = new Decision(Kind.DELIVER, 0, 0);
    }

    private static final class LossRule {
        final double rate; final long expires; final int channel; final int to; final Random rng; final long seed;
        LossRule(double rate, long expires, int channel, int to, long seed) {
            this.rate = rate; this.expires = expires; this.channel = channel; this.to = to; this.seed = seed; this.rng = new Random(seed);
        }
    }

    private static final class LatencyRule {
        final int minMs, maxMs; final long expires; final int channel; final Random rng;
        LatencyRule(int minMs, int maxMs, long expires, int channel, long seed) {
            this.minMs = minMs; this.maxMs = maxMs; this.expires = expires; this.channel = channel; this.rng = new Random(seed);
        }
    }

    private static final class Pending implements Comparable<Pending> {
        final long due; final long order; final Runnable deliver;
        Pending(long due, long order, Runnable deliver) { this.due = due; this.order = order; this.deliver = deliver; }
        @Override public int compareTo(Pending o) { return due != o.due ? Long.compare(due, o.due) : Long.compare(order, o.order); }
    }

    private final List<LossRule> loss = new CopyOnWriteArrayList<>();
    private final List<LatencyRule> latency = new CopyOnWriteArrayList<>();
    private final PriorityQueue<Pending> pending = new PriorityQueue<>();
    private long counter;

    public static final Faults INSTANCE = new Faults();

    public static final int ANY = -1;

    /** @return the seed used (the given one, or one drawn and reported so a run can say which it used) */
    public long addLoss(double rate, long nowTick, int durationSeconds, int channel, int to, Long seed) {
        long s = seed != null ? seed : new Random().nextInt(Integer.MAX_VALUE);
        loss.add(new LossRule(rate, nowTick + durationSeconds * 20L, channel, to, s));
        return s;
    }

    public long addLatency(int minMs, int maxMs, long nowTick, int durationSeconds, int channel, Long seed) {
        long s = seed != null ? seed : new Random().nextInt(Integer.MAX_VALUE);
        latency.add(new LatencyRule(minMs, Math.max(minMs, maxMs), nowTick + durationSeconds * 20L, channel, s));
        return s;
    }

    public void clear() {
        loss.clear();
        latency.clear();
    }

    public int activeRules(long nowTick) {
        int n = 0;
        for (LossRule r : loss) if (r.expires > nowTick) n++;
        for (LatencyRule r : latency) if (r.expires > nowTick) n++;
        return n;
    }

    /** Loss first (the first matching rule that hits), then latency (the first matching rule). */
    public Decision decide(long nowTick, int channel, int receiver) {
        for (LossRule r : loss) {
            if (r.expires <= nowTick) continue;
            if (r.channel != ANY && r.channel != channel) continue;
            if (r.to != ANY && r.to != receiver) continue;
            synchronized (r.rng) {
                if (r.rng.nextDouble() < r.rate) return new Decision(Kind.LOSE, 0, 0);
            }
        }
        for (LatencyRule r : latency) {
            if (r.expires <= nowTick) continue;
            if (r.channel != ANY && r.channel != channel) continue;
            int ms;
            synchronized (r.rng) {
                ms = r.minMs + (r.maxMs > r.minMs ? r.rng.nextInt(r.maxMs - r.minMs + 1) : 0);
            }
            int ticks = Math.max(1, (ms + TICK_MS - 1) / TICK_MS);
            return new Decision(Kind.DELAY, ticks, ms);
        }
        return Decision.DELIVER;
    }

    /** Queues a delivery for later; it runs on the server thread from {@link #pump}. */
    public synchronized void delay(long nowTick, int ticks, Runnable deliver) {
        pending.add(new Pending(nowTick + ticks, counter++, deliver));
    }

    /** Runs every delivery that is due, in due order (ties in the order they were queued). */
    public List<Runnable> due(long nowTick) {
        List<Runnable> out = new ArrayList<>();
        synchronized (this) {
            while (!pending.isEmpty() && pending.peek().due <= nowTick) out.add(pending.poll().deliver);
        }
        return out;
    }

    public synchronized int pendingCount() { return pending.size(); }
}
