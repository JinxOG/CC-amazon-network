package sandbox.t2control;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class FaultsTest {
    private Faults f() { return new Faults(); }

    @Test
    void nothingHappensUntilARuleIsAdded() {
        Faults f = f();
        for (int i = 0; i < 100; i++) assertEquals(Faults.Kind.DELIVER, f.decide(10, 1, 5).kind);
    }

    @Test
    void lossAtOneLosesEverythingAndAtZeroNothing() {
        Faults f = f();
        f.addLoss(1.0, 0, 60, Faults.ANY, Faults.ANY, 1L);
        for (int i = 0; i < 50; i++) assertEquals(Faults.Kind.LOSE, f.decide(5, 1, 5).kind);
        Faults g = f();
        g.addLoss(0.0, 0, 60, Faults.ANY, Faults.ANY, 1L);
        for (int i = 0; i < 50; i++) assertEquals(Faults.Kind.DELIVER, g.decide(5, 1, 5).kind);
    }

    @Test
    void theSameSeedGivesTheSameDecisions() {
        List<Faults.Kind> a = new ArrayList<>(), b = new ArrayList<>();
        Faults x = f(), y = f();
        x.addLoss(0.3, 0, 600, Faults.ANY, Faults.ANY, 42L);
        y.addLoss(0.3, 0, 600, Faults.ANY, Faults.ANY, 42L);
        for (int i = 0; i < 200; i++) { a.add(x.decide(1, 1, 1).kind); b.add(y.decide(1, 1, 1).kind); }
        assertEquals(a, b);
        long lost = a.stream().filter(k -> k == Faults.Kind.LOSE).count();
        assertTrue(lost > 30 && lost < 90, "about 30% lost, got " + lost);
    }

    @Test
    void aRuleCanBeLimitedToAChannelAndAReceiver() {
        Faults f = f();
        f.addLoss(1.0, 0, 60, 7, 12, 1L);
        assertEquals(Faults.Kind.LOSE, f.decide(1, 7, 12).kind);
        assertEquals(Faults.Kind.DELIVER, f.decide(1, 8, 12).kind);
        assertEquals(Faults.Kind.DELIVER, f.decide(1, 7, 13).kind);
    }

    @Test
    void aRuleExpiresByItselfInGameTime() {
        Faults f = f();
        f.addLoss(1.0, 100, 10, Faults.ANY, Faults.ANY, 1L);     // 10 game seconds = 200 ticks, from tick 100
        assertEquals(Faults.Kind.LOSE, f.decide(299, 1, 1).kind);
        assertEquals(Faults.Kind.DELIVER, f.decide(300, 1, 1).kind);
        assertEquals(0, f.activeRules(300));
        assertEquals(1, f.activeRules(299));
    }

    @Test
    void latencyDelaysByWholeTicksWithinTheRange() {
        Faults f = f();
        f.addLatency(100, 100, 0, 60, Faults.ANY, 1L);
        Faults.Decision d = f.decide(1, 1, 1);
        assertEquals(Faults.Kind.DELAY, d.kind);
        assertEquals(2, d.delayTicks);
        assertEquals(100, d.delayMs);
        Faults g = f();
        g.addLatency(10, 400, 0, 60, Faults.ANY, 3L);
        for (int i = 0; i < 100; i++) {
            Faults.Decision e = g.decide(1, 1, 1);
            assertTrue(e.delayMs >= 10 && e.delayMs <= 400 && e.delayTicks >= 1 && e.delayTicks <= 8, "ms " + e.delayMs);
        }
    }

    @Test
    void delayedPacketsComeOutInDueOrderAndTiesInQueueOrder() {
        Faults f = f();
        List<String> out = new ArrayList<>();
        f.delay(0, 5, () -> out.add("c"));
        f.delay(0, 2, () -> out.add("a"));
        f.delay(0, 2, () -> out.add("b"));
        assertEquals(0, f.due(1).size());
        f.due(2).forEach(Runnable::run);
        assertEquals(List.of("a", "b"), out);
        assertEquals(1, f.pendingCount());
        f.due(10).forEach(Runnable::run);
        assertEquals(List.of("a", "b", "c"), out);
    }

    @Test
    void lossIsTriedBeforeLatency() {
        Faults f = f();
        f.addLatency(100, 100, 0, 60, Faults.ANY, 1L);
        f.addLoss(1.0, 0, 60, Faults.ANY, Faults.ANY, 1L);
        assertEquals(Faults.Kind.LOSE, f.decide(1, 1, 1).kind);
    }

    @Test
    void clearRemovesEveryRule() {
        Faults f = f();
        f.addLoss(1.0, 0, 60, Faults.ANY, Faults.ANY, 1L);
        f.addLatency(100, 100, 0, 60, Faults.ANY, 1L);
        f.clear();
        assertEquals(Faults.Kind.DELIVER, f.decide(1, 1, 1).kind);
        assertEquals(0, f.activeRules(1));
    }
}
