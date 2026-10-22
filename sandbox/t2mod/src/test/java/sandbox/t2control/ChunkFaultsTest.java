package sandbox.t2control;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class ChunkFaultsTest {
    @Test
    void nothingIsRefusedUntilALoaderIsReleased() {
        assertFalse(new ChunkFaults().refuses(UUID.randomUUID(), 5));
    }

    @Test
    void aReleasedLoaderIsRefusedUntilTheDurationRunsOutAndNobodyElseIs() {
        ChunkFaults f = new ChunkFaults();
        UUID a = UUID.randomUUID(), b = UUID.randomUUID();
        f.release(a, 100, 10 * 20L, () -> {});
        assertTrue(f.refuses(a, 100));
        assertTrue(f.refuses(a, 299));
        assertFalse(f.refuses(a, 300));
        assertFalse(f.refuses(b, 150));
        assertEquals(1, f.activeCount(299));
        assertEquals(0, f.activeCount(300));
    }

    @Test
    void theRefusalIsLiftedBeforeTheTicketIsPutBack() {
        ChunkFaults f = new ChunkFaults();
        UUID a = UUID.randomUUID();
        List<Boolean> refusedWhenRestoring = new ArrayList<>();
        f.release(a, 0, 20, () -> refusedWhenRestoring.add(f.refuses(a, 20)));
        assertEquals(0, f.due(19).size());
        List<Runnable> due = f.due(20);
        assertEquals(1, due.size());
        due.forEach(Runnable::run);
        assertEquals(List.of(false), refusedWhenRestoring);
        assertEquals(0, f.due(1000).size(), "a ticket is put back once");
    }

    @Test
    void clearForgetsEveryReleaseWithoutRestoringAnything() {
        ChunkFaults f = new ChunkFaults();
        UUID a = UUID.randomUUID();
        f.release(a, 0, 20, () -> { throw new AssertionError("must not run"); });
        f.clear();
        assertFalse(f.refuses(a, 1));
        assertEquals(0, f.due(1000).size());
    }

    @Test
    void anAreaRefusesEveryChunkInsideItUntilItExpiresAndRestoresOnce() {
        ChunkFaults f = new ChunkFaults();
        List<String> log = new ArrayList<>();
        f.releaseArea(5, 3, -10, -12, 100, 40, () -> log.add("restored"));   // corners given in any order
        assertTrue(f.refusesChunk(3, -12, 100));
        assertTrue(f.refusesChunk(5, -10, 139));
        assertTrue(f.refusesChunk(4, -11, 120));
        assertFalse(f.refusesChunk(6, -11, 120));
        assertFalse(f.refusesChunk(4, -9, 120));
        assertFalse(f.refusesChunk(4, -11, 140));
        assertEquals(1, f.activeCount(139));
        assertEquals(0, f.due(139).size());
        f.due(140).forEach(Runnable::run);
        f.due(500).forEach(Runnable::run);
        assertEquals(List.of("restored"), log);
        assertEquals(0, f.activeCount(140));
    }
}
