package sandbox.t2control;

import java.lang.ref.WeakReference;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import de.srendi.advancedperipherals.common.addons.computercraft.owner.TurtlePeripheralOwner;
import de.srendi.advancedperipherals.common.addons.computercraft.peripheral.ChunkyPeripheral;
import de.srendi.advancedperipherals.common.util.ChunkManager;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import sandbox.t2control.mixin.ChunkCacheAccessor;
import sandbox.t2control.mixin.ChunkyAccessor;
import sandbox.t2control.mixin.DistanceManagerAccessor;

/** Chunk unload under a loader: which loader turtle belongs to which computer, and releasing / restoring its ticket. */
public final class Chunks {
    private Chunks() {}

    private static final Map<Integer, WeakReference<ChunkyPeripheral>> LOADERS = new ConcurrentHashMap<>();

    private static final java.util.concurrent.atomic.AtomicLong REFUSALS = new java.util.concurrent.atomic.AtomicLong();

    /** Counts a ticket request that was refused, so a run can show the refusal hook was what held the chunk down. */
    public static void refused() { REFUSALS.incrementAndGet(); }

    public static long refusals() { return REFUSALS.get(); }

    public static void attached(int computerId, ChunkyPeripheral p) { LOADERS.put(computerId, new WeakReference<>(p)); }

    public static void detached(int computerId, ChunkyPeripheral p) {
        WeakReference<ChunkyPeripheral> ref = LOADERS.get(computerId);
        if (ref != null && ref.get() == p) LOADERS.remove(computerId);
    }

    /** One line of JSON listing the loaders whose computers are loaded right now. */
    public static String list() {
        StringBuilder sb = new StringBuilder("{\"loaders\":[");
        boolean first = true;
        for (Map.Entry<Integer, WeakReference<ChunkyPeripheral>> e : LOADERS.entrySet()) {
            ChunkyPeripheral p = e.getValue().get();
            if (p == null) continue;
            ChunkPos pos = ((ChunkyAccessor) p).t2control$pos();
            if (pos == null) continue;
            if (!first) sb.append(',');
            first = false;
            sb.append("{\"computer\":").append(e.getKey()).append(",\"chunk_x\":").append(pos.x).append(",\"chunk_z\":").append(pos.z)
              .append(",\"uuid\":\"").append(((ChunkyAccessor) p).t2control$uuid()).append("\"}");
        }
        return sb.append("]}").toString();
    }

    /** Releases the loader's ticket for the given game seconds. Returns one line of JSON. */
    public static String unload(int computerId, int seconds, long nowTick) {
        WeakReference<ChunkyPeripheral> ref = LOADERS.get(computerId);
        ChunkyPeripheral p = ref == null ? null : ref.get();
        if (p == null) return "{\"error\":\"computer " + computerId + " has no loaded chunk-loader upgrade (not a loader, or its chunk is not loaded)\"}";
        ChunkyAccessor acc = (ChunkyAccessor) p;
        ChunkPos pos = acc.t2control$pos();
        UUID uuid = acc.t2control$uuid();
        if (pos == null) return "{\"error\":\"computer " + computerId + " has not asked for a chunk yet\"}";
        ServerLevel level = (ServerLevel) ((TurtlePeripheralOwner) p.getPeripheralOwner()).getLevel();
        ChunkManager cm = ChunkManager.get(level);
        ChunkFaults.INSTANCE.release(uuid, nowTick, seconds * 20L, () -> ChunkManager.get(level).addForceChunk(level, uuid, pos));
        boolean removed = cm.removeForceChunk(level, uuid);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("computer", computerId);
        args.put("duration_s", seconds);
        args.put("chunk_x", pos.x);
        args.put("chunk_z", pos.z);
        args.put("start_tick", nowTick);
        args.put("expires_tick", nowTick + seconds * 20L);
        String result = "{\"ok\":true,\"ticket_removed\":" + removed + ",\"chunk_x\":" + pos.x + ",\"chunk_z\":" + pos.z
                + ",\"expires_tick\":" + (nowTick + seconds * 20L) + "}";
        Logs.intervention("chunk_unload", args, result);
        return result;
    }

    /** What holds a chunk loaded: the vanilla ticket table entries for it (type, level), one line of JSON. */
    public static String tickets(net.minecraft.server.MinecraftServer server, int chunkX, int chunkZ) {
        ServerLevel level = server.overworld();
        net.minecraft.server.level.DistanceManager dm = ((ChunkCacheAccessor) level.getChunkSource()).t2control$distanceManager();
        var set = ((DistanceManagerAccessor) dm).t2control$tickets().get(ChunkPos.asLong(chunkX, chunkZ));
        StringBuilder sb = new StringBuilder("{\"chunk_x\":").append(chunkX).append(",\"chunk_z\":").append(chunkZ).append(",\"tickets\":[");
        if (set != null) {
            boolean first = true;
            for (var t : set) {
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(describe(t).replace("\\", "/").replace("\"", "'")).append('"');
            }
        }
        return sb.append("]}").toString();
    }

    /** A ticket as text: its type, level, and (for a Forge ticket) the mod id and owner that hold it - found by field type, so no obfuscated name is needed. */
    private static String describe(Object ticket) {
        StringBuilder sb = new StringBuilder(String.valueOf(ticket).replaceAll("\\(net\\.minecraftforge[^)]*\\)", ""));
        try {
            for (java.lang.reflect.Field f : ticket.getClass().getDeclaredFields()) {
                f.setAccessible(true);
                Object v = f.get(ticket);
                if (v != null && v.getClass().getName().endsWith("TicketOwner")) {
                    java.lang.reflect.Field m = v.getClass().getDeclaredField("modId");
                    java.lang.reflect.Field o = v.getClass().getDeclaredField("owner");
                    m.setAccessible(true);
                    o.setAccessible(true);
                    sb.append(" mod=").append(m.get(v)).append(" owner=").append(o.get(v));
                }
            }
        } catch (ReflectiveOperationException | RuntimeException e) {
            sb.append(" (owner unreadable: ").append(e.getClass().getSimpleName()).append(')');
        }
        return sb.toString();
    }

    private static final class Held {
        final String modId; final Object owner; final int cx, cz; final boolean ticking;
        Held(String modId, Object owner, int cx, int cz, boolean ticking) { this.modId = modId; this.owner = owner; this.cx = cx; this.cz = cz; this.ticking = ticking; }
    }

    private static Object ticketField(Object ticket, String name) throws ReflectiveOperationException {
        for (java.lang.reflect.Field f : ticket.getClass().getDeclaredFields()) {
            f.setAccessible(true);
            Object v = f.get(ticket);
            if (v != null && v.getClass().getName().endsWith("TicketOwner")) {
                java.lang.reflect.Field m = v.getClass().getDeclaredField(name);
                m.setAccessible(true);
                return m.get(v);
            }
        }
        return null;
    }

    private static boolean force(ServerLevel level, Held h, boolean add) {
        if (h.owner instanceof net.minecraft.core.BlockPos) {
            return net.minecraftforge.common.world.ForgeChunkManager.forceChunk(level, h.modId, (net.minecraft.core.BlockPos) h.owner, h.cx, h.cz, add, h.ticking);
        }
        if (h.owner instanceof UUID) {
            return net.minecraftforge.common.world.ForgeChunkManager.forceChunk(level, h.modId, (UUID) h.owner, h.cx, h.cz, add, h.ticking);
        }
        return false;
    }

    /**
     * Releases EVERY Forge chunk ticket (any mod: Advanced Peripherals, the Chunk Loaders mod, ...) on the chunks that overlap the block box,
     * refuses new ones there for the duration, and puts the old ones back at the end. This is the simulator's chunk_unload(area).
     */
    public static String unloadArea(net.minecraft.server.MinecraftServer server, int x1, int z1, int x2, int z2, int seconds, long nowTick) {
        ServerLevel level = server.overworld();
        int minCx = Math.min(x1, x2) >> 4, maxCx = Math.max(x1, x2) >> 4, minCz = Math.min(z1, z2) >> 4, maxCz = Math.max(z1, z2) >> 4;
        if ((maxCx - minCx + 1) * (maxCz - minCz + 1) > 1089) return "{\"error\":\"area is larger than 33 x 33 chunks\"}";
        var table = ((DistanceManagerAccessor) ((ChunkCacheAccessor) level.getChunkSource()).t2control$distanceManager()).t2control$tickets();
        java.util.List<Held> held = new java.util.ArrayList<>();
        java.util.Map<String, Integer> byMod = new java.util.TreeMap<>();
        int skipped = 0;
        for (int cx = minCx; cx <= maxCx; cx++) {
            for (int cz = minCz; cz <= maxCz; cz++) {
                var set = table.get(ChunkPos.asLong(cx, cz));
                if (set == null) continue;
                for (var t : new java.util.ArrayList<Object>(set)) {
                    String text = String.valueOf(t);
                    if (!text.contains("forge:")) continue;
                    try {
                        Object mod = ticketField(t, "modId");
                        Object owner = ticketField(t, "owner");
                        if (mod == null || owner == null) { skipped++; continue; }
                        Held h = new Held(String.valueOf(mod), owner, cx, cz, text.contains("forge:entity_ticking"));
                        if (!(owner instanceof net.minecraft.core.BlockPos) && !(owner instanceof UUID)) { skipped++; continue; }
                        held.add(h);
                        byMod.merge(h.modId, 1, Integer::sum);
                    } catch (ReflectiveOperationException | RuntimeException e) {
                        skipped++;
                    }
                }
            }
        }
        // the restore action first (it must exist before the refusal is installed), then the refusal, then the removals
        ChunkFaults.INSTANCE.releaseArea(minCx, maxCx, minCz, maxCz, nowTick, seconds * 20L, () -> {
            for (Held h : held) force(level, h, true);
        });
        int removed = 0;
        for (Held h : held) if (force(level, h, false)) removed++;
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("x1", x1); args.put("z1", z1); args.put("x2", x2); args.put("z2", z2); args.put("duration_s", seconds);
        args.put("chunks", (maxCx - minCx + 1) * (maxCz - minCz + 1)); args.put("tickets_released", removed); args.put("by_mod", byMod);
        args.put("start_tick", nowTick); args.put("expires_tick", nowTick + seconds * 20L);
        String result = "{\"ok\":true,\"tickets_released\":" + removed + ",\"found\":" + held.size() + ",\"skipped\":" + skipped
                + ",\"by_mod\":" + new com.google.gson.Gson().toJson(byMod) + ",\"expires_tick\":" + (nowTick + seconds * 20L) + "}";
        Logs.intervention("chunk_unload_area", args, result);
        return result;
    }

    private static final UUID PROBE = UUID.fromString("00000000-0000-4000-8000-0000007e57e5");

    /** Asks Forge for a ticket on one chunk through the same method every chunk-loading mod uses, and gives it back at once. Says whether it was accepted. */
    public static String probe(net.minecraft.server.MinecraftServer server, int chunkX, int chunkZ) {
        ServerLevel level = server.overworld();
        boolean accepted = net.minecraftforge.common.world.ForgeChunkManager.forceChunk(level, "t2control", PROBE, chunkX, chunkZ, true, false);
        if (accepted) net.minecraftforge.common.world.ForgeChunkManager.forceChunk(level, "t2control", PROBE, chunkX, chunkZ, false, false);
        return "{\"accepted\":" + accepted + ",\"refusals\":" + refusals() + "}";
    }
}
