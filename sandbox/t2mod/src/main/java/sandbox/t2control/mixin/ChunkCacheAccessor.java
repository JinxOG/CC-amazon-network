package sandbox.t2control.mixin;

import net.minecraft.server.level.DistanceManager;
import net.minecraft.server.level.ServerChunkCache;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Reaches the vanilla chunk ticket table so a run can say what is holding a chunk loaded. */
@Mixin(ServerChunkCache.class)
public interface ChunkCacheAccessor {
    @Accessor("distanceManager")
    DistanceManager t2control$distanceManager();
}
