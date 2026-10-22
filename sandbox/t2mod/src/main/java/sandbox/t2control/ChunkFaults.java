package sandbox.t2control;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Chunk-unload faults (spec section 6): while a loader is "released", Advanced Peripherals is refused any new ticket for that
 * loader; when the time is up the refusal is lifted and the ticket is put back by the restore action, because an unloaded
 * turtle cannot ask for its own chunk. Pure logic (no Minecraft types) so it can be unit tested.
 */
public final class ChunkFaults {
    public static final ChunkFaults INSTANCE = new ChunkFaults();

    private static final class Release {
        final long expires;
        final Runnable restore;
        Release(long expires, Runnable restore) { this.expires = expires; this.restore = restore; }
    }

    private final Map<UUID, Release> released = new ConcurrentHashMap<>();

    private static final class AreaRelease {
        final int minX, maxX, minZ, maxZ;
        final long expires;
        final Runnable restore;
        AreaRelease(int minX, int maxX, int minZ, int maxZ, long expires, Runnable restore) {
            this.minX = minX; this.maxX = maxX; this.minZ = minZ; this.maxZ = maxZ; this.expires = expires; this.restore = restore;
        }
    }

    private final java.util.List<AreaRelease> areas = new java.util.concurrent.CopyOnWriteArrayList<>();

    /** Refuses every new ticket on chunks inside the box (chunk coordinates, inclusive) until tick nowTick + ticks; restore puts the old tickets back. */
    public void releaseArea(int minChunkX, int maxChunkX, int minChunkZ, int maxChunkZ, long nowTick, long ticks, Runnable restore) {
        areas.add(new AreaRelease(Math.min(minChunkX, maxChunkX), Math.max(minChunkX, maxChunkX), Math.min(minChunkZ, maxChunkZ), Math.max(minChunkZ, maxChunkZ), nowTick + ticks, restore));
    }

    public boolean refusesChunk(int chunkX, int chunkZ, long nowTick) {
        for (AreaRelease a : areas) {
            if (a.expires > nowTick && chunkX >= a.minX && chunkX <= a.maxX && chunkZ >= a.minZ && chunkZ <= a.maxZ) return true;
        }
        return false;
    }

    /** Starts refusing tickets for this loader until tick nowTick + ticks; restore puts the ticket back at expiry. */
    public void release(UUID loader, long nowTick, long ticks, Runnable restore) {
        released.put(loader, new Release(nowTick + ticks, restore));
    }

    public boolean refuses(UUID loader, long nowTick) {
        Release r = released.get(loader);
        return r != null && r.expires > nowTick;
    }

    public int activeCount(long nowTick) {
        int n = 0;
        for (Release r : released.values()) if (r.expires > nowTick) n++;
        for (AreaRelease a : areas) if (a.expires > nowTick) n++;
        return n;
    }

    /** Lifts every refusal that has run out and returns the restore actions (the refusal is gone BEFORE they run). */
    public List<Runnable> due(long nowTick) {
        List<Runnable> out = new ArrayList<>();
        for (Map.Entry<UUID, Release> e : released.entrySet()) {
            if (e.getValue().expires <= nowTick && released.remove(e.getKey(), e.getValue())) out.add(e.getValue().restore);
        }
        for (AreaRelease a : areas) {
            if (a.expires <= nowTick && areas.remove(a)) out.add(a.restore);
        }
        return out;
    }

    public void clear() {
        released.clear();
        areas.clear();
    }
}
