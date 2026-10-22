package sandbox.t2control.mixin;

import java.util.function.Function;

import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.TicketType;
import net.minecraftforge.common.world.ForgeChunkManager;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import sandbox.t2control.ChunkFaults;
import sandbox.t2control.Chunks;
import sandbox.t2control.T2Control;

/**
 * The refusal hook for a released AREA: every chunk-loading mod that uses Forge's ticket system (Advanced Peripherals, the Chunk Loaders mod,
 * FTB Chunks...) ends up in this one method. While an area is released, a request to ADD a ticket on a chunk inside it is refused.
 */
@Mixin(value = ForgeChunkManager.class, remap = false)
public abstract class ForgeChunkManagerMixin {
    @Inject(method = "forceChunk(Lnet/minecraft/server/level/ServerLevel;Ljava/lang/String;Ljava/lang/Comparable;IIZZLnet/minecraft/server/level/TicketType;Ljava/util/function/Function;)Z",
            at = @At("HEAD"), cancellable = true, remap = false)
    private static void t2control$refuseArea(ServerLevel level, String modId, Comparable<?> owner, int chunkX, int chunkZ, boolean add, boolean ticking,
                                             TicketType<?> type, Function<?, ?> tracker, CallbackInfoReturnable<Boolean> cir) {
        if (add && ChunkFaults.INSTANCE.refusesChunk(chunkX, chunkZ, T2Control.currentTick())) {
            Chunks.refused();
            cir.setReturnValue(false);
        }
    }
}
