package sandbox.t2control.mixin;

import java.util.UUID;

import de.srendi.advancedperipherals.common.addons.computercraft.peripheral.ChunkyPeripheral;
import net.minecraft.world.level.ChunkPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
import org.spongepowered.asm.mixin.gen.Invoker;

/** Reads a chunk-loader upgrade's ticket id and the chunk it asked for. */
@Mixin(value = ChunkyPeripheral.class, remap = false)
public interface ChunkyAccessor {
    @Invoker("getUUID")
    UUID t2control$uuid();

    @Accessor("loadedCentralChunk")
    ChunkPos t2control$pos();
}
