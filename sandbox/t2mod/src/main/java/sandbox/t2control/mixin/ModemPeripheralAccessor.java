package sandbox.t2control.mixin;

import java.util.Set;

import dan200.computercraft.api.peripheral.IComputerAccess;
import dan200.computercraft.shared.peripheral.modem.ModemPeripheral;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Reads the computers a modem is attached to, to name the receiver of a radio message. */
@Mixin(value = ModemPeripheral.class, remap = false)
public interface ModemPeripheralAccessor {
    @Accessor("computers")
    Set<IComputerAccess> t2control$computers();
}
