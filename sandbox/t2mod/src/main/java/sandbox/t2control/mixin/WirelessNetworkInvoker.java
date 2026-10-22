package sandbox.t2control.mixin;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.shared.peripheral.modem.wireless.WirelessNetwork;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

/** Calls the private static tryTransmit again, to deliver a delayed packet through the original code. */
@Mixin(value = WirelessNetwork.class, remap = false)
public interface WirelessNetworkInvoker {
    @Invoker("tryTransmit")
    static void t2control$tryTransmit(PacketReceiver receiver, Packet packet, double range, boolean interdimensional) {
        throw new AssertionError("replaced by Mixin");
    }
}
