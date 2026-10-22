package sandbox.t2control.mixin;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.api.network.PacketSender;
import dan200.computercraft.api.peripheral.IComputerAccess;
import dan200.computercraft.shared.peripheral.modem.ModemPeripheral;
import dan200.computercraft.shared.peripheral.modem.wireless.WirelessNetwork;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import sandbox.t2control.Logs;

/**
 * The radio hook (spec section 4): WirelessNetwork#tryTransmit is called once per receiver of a wireless packet, whether or not
 * that receiver is in range or has the channel open. The hook repeats CC's own range test and the modem's channel test, and logs
 * only a packet that WOULD reach a program (unless "radio log on all" asks for the rest, outcome "not_reached"). M2 adds loss
 * and latency at this point.
 */
@Mixin(value = WirelessNetwork.class, remap = false)
public abstract class WirelessNetworkMixin {
    @Inject(method = "tryTransmit", at = @At("HEAD"), remap = false)
    private static void t2control$log(PacketReceiver receiver, Packet packet, double range, boolean interdimensional, CallbackInfo ci) {
        if (!Logs.RADIO_ON.get()) return;
        PacketSender sender = packet.sender();
        Vec3 from = sender.getPosition();
        boolean sameLevel = receiver.getLevel() == sender.getLevel();
        double distance = 0;
        boolean inRange;
        if (sameLevel) {
            double receiverRange = Math.max(range, receiver.getRange());
            double distanceSq = receiver.getPosition().distanceToSqr(from);
            distance = Math.sqrt(distanceSq);
            inRange = interdimensional || receiver.isInterdimensional() || distanceSq <= receiverRange * receiverRange;
        } else {
            inRange = interdimensional || receiver.isInterdimensional();
        }
        boolean open = !(receiver instanceof ModemPeripheral) || ((ModemPeripheral) receiver).getModemState().isOpen(packet.channel());
        boolean reached = inRange && open;
        if (!reached && !Logs.RADIO_ALL.get()) return;
        String body = String.valueOf(packet.payload());
        int[] ids = new int[0];
        if (receiver instanceof ModemPeripheral) {
            java.util.Set<IComputerAccess> computers = ((ModemPeripheralAccessor) receiver).t2control$computers();
            synchronized (receiver) {
                ids = computers.stream().mapToInt(IComputerAccess::getID).toArray();
            }
        }
        String outcome = reached ? "delivered" : (inRange ? "not_reached:channel_closed" : "not_reached:out_of_range");
        if (ids.length == 0) {
            Logs.radio(from.x, from.y, from.z, sender.getSenderID(), -1, packet.channel(), packet.replyChannel(), distance, body, outcome);
        }
        for (int id : ids) {
            Logs.radio(from.x, from.y, from.z, sender.getSenderID(), id, packet.channel(), packet.replyChannel(), distance, body, outcome);
        }
    }
}
