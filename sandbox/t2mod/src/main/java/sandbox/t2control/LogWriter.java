package sandbox.t2control;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.atomic.AtomicLong;

/**
 * One JSON-lines file written by a background thread (spec section 7): the server thread only offers a line to a bounded queue,
 * never blocks, and when the queue is full the line is dropped AND COUNTED, so a log that lost lines cannot look like evidence.
 * The file rotates at ROTATE_BYTES (the old one is kept as name.1.jsonl).
 */
public final class LogWriter {
    public static final long ROTATE_BYTES = 256L * 1024 * 1024;
    private static final String POISON = "\u0000stop";

    private final Path file;
    private final BlockingQueue<String> queue;
    private final AtomicLong written = new AtomicLong();
    private final AtomicLong dropped = new AtomicLong();
    private final Thread thread;
    private volatile boolean running = true;

    public LogWriter(Path file, int capacity) {
        this.file = file;
        this.queue = new ArrayBlockingQueue<>(capacity);
        this.thread = new Thread(this::loop, "t2control-writer-" + file.getFileName());
        this.thread.setDaemon(true);
        this.thread.start();
    }

    /** Called from any thread; never blocks. Returns false (and counts it) when the line was dropped. */
    public boolean offer(String line) {
        if (!running || !queue.offer(line)) {
            dropped.incrementAndGet();
            return false;
        }
        return true;
    }

    public long written() { return written.get(); }

    public long dropped() { return dropped.get(); }

    public int queued() { return queue.size(); }

    public Path file() { return file; }

    private void loop() {
        long size = 0;
        try {
            Files.createDirectories(file.getParent());
            if (Files.exists(file)) size = Files.size(file);
            BufferedWriter out = Files.newBufferedWriter(file, StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            try {
                while (true) {
                    String line = queue.take();
                    if (POISON.equals(line)) break;
                    out.write(line);
                    out.write('\n');
                    written.incrementAndGet();
                    size += line.length() + 1;
                    if (queue.isEmpty()) out.flush();
                    if (size >= ROTATE_BYTES) {
                        out.close();
                        Path old = file.resolveSibling(file.getFileName().toString().replace(".jsonl", ".1.jsonl"));
                        Files.move(file, old, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                        out = Files.newBufferedWriter(file, StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
                        size = 0;
                    }
                }
            } finally {
                out.flush();
                out.close();
            }
        } catch (IOException | InterruptedException e) {
            running = false;
        }
    }

    /** Waits for what is queued to be written (used by tests and at shutdown). */
    public void close() {
        running = false;
        queue.offer(POISON);
        try {
            thread.join(5000);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }
}
