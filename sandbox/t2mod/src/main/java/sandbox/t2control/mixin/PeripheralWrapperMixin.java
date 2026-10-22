package sandbox.t2control.mixin;

import dan200.computercraft.api.lua.IArguments;
import dan200.computercraft.api.lua.ILuaContext;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.MethodResult;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import sandbox.t2control.PeripheralFaults;
import sandbox.t2control.T2Control;

/**
 * The peripheral hook (spec M5): every call a program makes to a peripheral it wrapped goes through PeripheralWrapper#call on the
 * computer's own thread. A stall waits on that thread before the call runs (the program sees the call take longer; the server tick is not
 * touched); a failure raises an error to the program instead of calling the peripheral.
 */
@Mixin(targets = "dan200.computercraft.core.apis.PeripheralAPI$PeripheralWrapper", remap = false)
public abstract class PeripheralWrapperMixin {
    @Shadow
    private String type;

    @Inject(method = "call", at = @At("HEAD"), remap = false, cancellable = true)
    private void t2control$fault(ILuaContext context, String methodName, IArguments arguments, CallbackInfoReturnable<MethodResult> cir) throws LuaException {
        PeripheralFaults.Decision d = PeripheralFaults.INSTANCE.decide(type, T2Control.currentTick());
        if (d.kind == PeripheralFaults.Kind.NONE) return;
        if (d.kind == PeripheralFaults.Kind.FAIL) {
            throw new LuaException("T2 fault: " + type + " is not reachable");
        }
        try {
            Thread.sleep(d.extraMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
