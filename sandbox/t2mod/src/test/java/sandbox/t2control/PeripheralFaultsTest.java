package sandbox.t2control;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class PeripheralFaultsTest {
    @Test
    void nothingHappensUntilARuleIsAdded() {
        assertEquals(PeripheralFaults.Kind.NONE, new PeripheralFaults().decide("rsBridge", 5).kind);
    }

    @Test
    void aStallAppliesToItsTypeOnlyAndEndsByItself() {
        PeripheralFaults f = new PeripheralFaults();
        f.addStall("rsBridge", 1500, 100, 10);               // 10 game seconds = 200 ticks
        PeripheralFaults.Decision d = f.decide("rsBridge", 150);
        assertEquals(PeripheralFaults.Kind.STALL, d.kind);
        assertEquals(1500, d.extraMs);
        assertEquals(PeripheralFaults.Kind.NONE, f.decide("modem", 150).kind);
        assertEquals(PeripheralFaults.Kind.STALL, f.decide("rsBridge", 299).kind);
        assertEquals(PeripheralFaults.Kind.NONE, f.decide("rsBridge", 300).kind);
        assertEquals(0, f.activeRules(300));
    }

    @Test
    void aFailureWinsOverAStallAndCountsWhatItDid() {
        PeripheralFaults f = new PeripheralFaults();
        f.addStall("rsBridge", 500, 0, 60);
        f.addFail("rsBridge", 0, 60);
        assertEquals(PeripheralFaults.Kind.FAIL, f.decide("rsBridge", 1).kind);
        assertEquals(1, f.failedCalls());
        assertEquals(0, f.stalledCalls());
    }

    @Test
    void clearRemovesEveryRule() {
        PeripheralFaults f = new PeripheralFaults();
        f.addFail("rsBridge", 0, 60);
        f.clear();
        assertEquals(PeripheralFaults.Kind.NONE, f.decide("rsBridge", 1).kind);
    }
}
