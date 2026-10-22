package sandbox.t2control.mixin;

import dan200.computercraft.api.peripheral.IComputerAccess;
import de.srendi.advancedperipherals.common.addons.computercraft.peripheral.ChunkyPeripheral;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import sandbox.t2control.Chunks;

/** Learns which computer a chunk-loader upgrade belongs to (attach is when its computer starts, detach when it stops). */
@Mixin(value = ChunkyPeripheral.class, remap = false)
public abstract class ChunkyPeripheralMixin {
    @Inject(method = "attach", at = @At("TAIL"), remap = false)
    private void t2control$attach(IComputerAccess computer, CallbackInfo ci) {
        Chunks.attached(computer.getID(), (ChunkyPeripheral) (Object) this);
    }

    @Inject(method = "detach", at = @At("TAIL"), remap = false)
    private void t2control$detach(IComputerAccess computer, CallbackInfo ci) {
        Chunks.detached(computer.getID(), (ChunkyPeripheral) (Object) this);
    }
}
