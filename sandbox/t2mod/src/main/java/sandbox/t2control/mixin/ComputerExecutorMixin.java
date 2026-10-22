package sandbox.t2control.mixin;

import java.util.Arrays;

import dan200.computercraft.core.computer.Computer;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import sandbox.t2control.Logs;

/**
 * The event hook. Every event a computer is handed (timers, turtle responses, modem messages, peripheral events) goes through
 * ComputerExecutor#queueEvent, whether it arrives via ServerComputer or via a peripheral's IComputerAccess, so this is the single
 * choke point (the design named ServerComputer#queueEvent, which misses modem_message). It logs what was QUEUED; whether the
 * program then consumed the event, or a filtered yield ate it, is not visible here (the report says so).
 */
@Mixin(targets = "dan200.computercraft.core.computer.ComputerExecutor", remap = false)
public abstract class ComputerExecutorMixin {
    @Shadow @Final private Computer computer;

    @Inject(method = "queueEvent", at = @At("HEAD"), remap = false)
    private void t2control$log(String event, Object[] args, CallbackInfo ci) {
        if (!Logs.EVENTS_ON.get()) return;
        Logs.event(computer.getID(), event, args == null ? "" : Arrays.toString(args));
    }
}
