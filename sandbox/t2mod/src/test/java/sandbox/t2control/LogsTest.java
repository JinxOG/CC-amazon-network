package sandbox.t2control;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class LogsTest {
    @TempDir
    Path dir;

    @AfterEach
    void close() {
        Logs.close();
        Logs.RADIO_ON.set(false);
        Logs.EVENTS_ON.set(false);
    }

    @Test
    void writerKeepsOrderAndFlushesOnClose() throws Exception {
        LogWriter w = new LogWriter(dir.resolve("a.jsonl"), 100);
        for (int i = 0; i < 50; i++) assertTrue(w.offer("line " + i));
        w.close();
        List<String> lines = Files.readAllLines(dir.resolve("a.jsonl"));
        assertEquals(50, lines.size());
        assertEquals("line 0", lines.get(0));
        assertEquals("line 49", lines.get(49));
        assertEquals(0, w.dropped());
    }

    @Test
    void aFullQueueDropsAndCountsInsteadOfBlocking() throws Exception {
        // a writer whose file cannot be created never drains: the queue fills, then every line is dropped and counted
        Path blocked = dir.resolve("file-not-dir");
        Files.writeString(blocked, "x");
        LogWriter w = new LogWriter(blocked.resolve("sub/x.jsonl"), 5);
        Thread.sleep(300);
        long start = System.nanoTime();
        int accepted = 0;
        for (int i = 0; i < 1000; i++) if (w.offer("l" + i)) accepted++;
        assertTrue((System.nanoTime() - start) / 1_000_000 < 500, "offer must not block");
        assertEquals(1000 - accepted, w.dropped());
        assertTrue(w.dropped() >= 995 - 5);
    }

    @Test
    void radioLinesCarryEverythingAndAreOffUntilSwitchedOn() throws Exception {
        Logs.open(dir, () -> 1234L);
        Logs.radio(10.4, 67, -2800.6, "turtle@x", 181, 1, 1181, 12.34, "hello", "delivered");
        Logs.close();
        assertTrue(!Files.exists(dir.resolve("radio.jsonl")) || Files.readAllLines(dir.resolve("radio.jsonl")).isEmpty(), "off by default");

        Logs.open(dir, () -> 1234L);
        Logs.RADIO_ON.set(true);
        Logs.radio(10.4, 67, -2800.6, "turtle@x", 181, 1, 1181, 12.34, "hello", "delivered");
        Logs.close();
        List<String> lines = Files.readAllLines(dir.resolve("radio.jsonl"));
        assertEquals(1, lines.size());
        String l = lines.get(0);
        for (String part : new String[] {"\"tick\":1234", "\"to\":181", "\"channel\":1", "\"reply_channel\":1181", "\"body\":\"hello\"",
                "\"body_length\":5", "\"outcome\":\"delivered\"", "\"from_pos\":\"10,67,-2801\"", "\"distance\":12.3"}) {
            assertTrue(l.contains(part), part + " in " + l);
        }
    }

    @Test
    void aLongBodyIsClippedButItsLengthIsKept() throws Exception {
        Logs.open(dir, () -> 1L);
        Logs.RADIO_ON.set(true);
        Logs.radio(0, 0, 0, "s", 1, 1, 1, 0, "x".repeat(5000), "delivered");
        Logs.close();
        String l = Files.readAllLines(dir.resolve("radio.jsonl")).get(0);
        assertTrue(l.contains("\"body_length\":5000"));
        assertTrue(l.length() < 2400, "line length " + l.length());
    }

    @Test
    void interventionsAreAlwaysRecorded() throws Exception {
        Logs.open(dir, () -> 7L);
        Logs.intervention("radio_log", Map.of("state", "on"), "{\"ok\":true}");
        Logs.close();
        String l = Files.readAllLines(dir.resolve("interventions.jsonl")).get(0);
        assertTrue(l.contains("\"verb\":\"radio_log\"") && l.contains("\"state\":\"on\""), l);
    }

    @Test
    void eventLinesNameTheComputerAndTheEvent() throws Exception {
        Logs.open(dir, () -> 9L);
        Logs.EVENTS_ON.set(true);
        Logs.event(183, "timer", "[5]");
        Logs.close();
        String l = Files.readAllLines(dir.resolve("events.jsonl")).get(0);
        assertTrue(l.contains("\"computer\":183") && l.contains("\"event\":\"timer\"") && l.contains("\"args\":\"[5]\""), l);
    }
}
