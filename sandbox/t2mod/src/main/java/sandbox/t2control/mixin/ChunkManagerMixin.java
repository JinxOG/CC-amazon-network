package sandbox.t2control.mixin;

import java.util.UUID;

import de.srendi.advancedperipherals.common.util.ChunkManager;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import sandbox.t2control.ChunkFaults;
import sandbox.t2control.Chunks;
import sandbox.t2control.T2Control;

/** The refusal hook: while a loader is released, Advanced Peripherals is told its ticket request failed. Without this the loader asks again at once. */
@Mixin(value = ChunkManager.class, remap = false)
public abstract class ChunkManagerMixin {
    @Inject(method = "addForceChunk", at = @At("HEAD"), cancellable = true, remap = false)
    private void t2control$refuse(ServerLevel level, UUID id, ChunkPos pos, CallbackInfoReturnable<Boolean> cir) {
        if (ChunkFaults.INSTANCE.refuses(id, T2Control.currentTick())) {
            Chunks.refused();
            cir.setReturnValue(false);
        }
    }
}
