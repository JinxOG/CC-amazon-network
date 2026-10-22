package sandbox.t2control.mixin;

import java.util.function.BooleanSupplier;

import net.minecraft.server.MinecraftServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import sandbox.t2control.PauseControl;

/** Pause and step (spec M6): a tick that is not allowed to run is cancelled before it starts. */
@Mixin(MinecraftServer.class)
public abstract class MinecraftServerMixin {
    @Inject(method = "tickServer", at = @At("HEAD"), cancellable = true)
    private void t2control$pause(BooleanSupplier hasTimeLeft, CallbackInfo ci) {
        if (!PauseControl.INSTANCE.shouldRun()) ci.cancel();
    }
}
