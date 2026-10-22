package sandbox.t2control.mixin;

import java.util.Set;

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
import sandbox.t2control.Faults;
import sandbox.t2control.Logs;
import sandbox.t2control.T2Control;

/**
 * The radio hook (spec section 4): WirelessNetwork#tryTransmit is called once per receiver of a wireless packet, whether or not
 * that receiver is in range or has the channel open. The hook repeats CC's own range test and the modem's channel test, so it knows
 * which packets WOULD reach a program. Those are logged (outcome "delivered", or "lost" / "delayed:<ms>") and are where radio
 * loss and latency act: a lost packet is cancelled; a delayed one is cancelled and delivered again through the original method
 * later (a game tick at a time). Packets that would not reach a program are left alone (and logged only by "radio log all").
 */
@Mixin(value = WirelessNetwork.class, remap = false)
public abstract class WirelessNetworkMixin {
    /** True while a delayed packet is being delivered again, so it is not delayed twice. */
    private static final ThreadLocal<Boolean> REDELIVERING = ThreadLocal.withInitial(() -> false);

    @Inject(method = "tryTransmit", at = @At("HEAD"), remap = false, cancellable = true)
    private static void t2control$hook(PacketReceiver receiver, Packet packet, double range, boolean interdimensional, CallbackInfo ci) {
        if (REDELIVERING.get()) return;
        long now = T2Control.currentTick();
        boolean faults = Faults.INSTANCE.activeRules(now) > 0;
        boolean logging = Logs.RADIO_ON.get();
        if (!faults && !logging) return;

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

        int[] ids = new int[0];
        if (receiver instanceof ModemPeripheral) {
            ids = receiverIds((ModemPeripheral) receiver);
        }
        int to = ids.length > 0 ? ids[0] : -1;
        String body = logging ? String.valueOf(packet.payload()) : "";

        String outcome = reached ? "delivered" : (inRange ? "not_reached:channel_closed" : "not_reached:out_of_range");
        if (reached && faults) {
            Faults.Decision d = Faults.INSTANCE.decide(now, packet.channel(), to);
            if (d.kind == Faults.Kind.LOSE) {
                log(logging, from, sender, ids, packet, distance, body, "lost");
                ci.cancel();
                return;
            }
            if (d.kind == Faults.Kind.DELAY) {
                log(logging, from, sender, ids, packet, distance, body, "delayed:" + d.delayMs);
                final PacketReceiver r = receiver;
                final int[] idsF = ids;
                final double rng = range;
                final boolean inter = interdimensional;
                Faults.INSTANCE.delay(now, d.delayTicks, () -> {
                    if (r instanceof ModemPeripheral && receiverIds((ModemPeripheral) r).length == 0) {
                        log(Logs.RADIO_ON.get(), from, sender, idsF, packet, 0, Logs.RADIO_ON.get() ? String.valueOf(packet.payload()) : "", "dropped_receiver_gone");
                        return;
                    }
                    REDELIVERING.set(true);
                    try {
                        WirelessNetworkInvoker.t2control$tryTransmit(r, packet, rng, inter);
                    } finally {
                        REDELIVERING.set(false);
                    }
                });
                ci.cancel();
                return;
            }
        }
        log(logging, from, sender, ids, packet, distance, body, outcome);
    }

    private static int[] receiverIds(ModemPeripheral receiver) {
        Set<IComputerAccess> computers = ((ModemPeripheralAccessor) receiver).t2control$computers();
        synchronized (receiver) {
            return computers.stream().mapToInt(IComputerAccess::getID).toArray();
        }
    }

    private static void log(boolean logging, Vec3 from, PacketSender sender, int[] ids, Packet packet, double distance, String body, String outcome) {
        if (!logging) return;
        if (ids.length == 0) {
            Logs.radio(from.x, from.y, from.z, sender.getSenderID(), -1, packet.channel(), packet.replyChannel(), distance, body, outcome);
        }
        for (int id : ids) {
            Logs.radio(from.x, from.y, from.z, sender.getSenderID(), id, packet.channel(), packet.replyChannel(), distance, body, outcome);
        }
    }
}
