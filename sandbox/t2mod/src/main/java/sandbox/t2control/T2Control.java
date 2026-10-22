package sandbox.t2control;

import java.io.IOException;
import java.io.Reader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Properties;

import net.minecraft.server.MinecraftServer;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.RegisterCommandsEvent;
import net.minecraftforge.event.server.ServerStartedEvent;
import net.minecraftforge.event.server.ServerStoppingEvent;
import net.minecraftforge.eventbus.api.IEventBus;
import net.minecraftforge.fml.ModList;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.event.lifecycle.FMLCommonSetupEvent;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import net.minecraftforge.fml.loading.FMLPaths;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

/** The T2 control mod (spec docs/superpowers/specs/2026-10-20-t2-control-mod-design.md). M0: the load guard. M1: the logs. */
@Mod(T2Control.MOD_ID)
public class T2Control {
    public static final String MOD_ID = "t2control";
    private static final Logger LOGGER = LogManager.getLogger("t2control");
    private static volatile MinecraftServer server;

    public T2Control() {
        IEventBus bus = FMLJavaModLoadingContext.get().getModEventBus();
        bus.addListener(this::commonSetup);
        MinecraftForge.EVENT_BUS.addListener(this::onCommands);
        MinecraftForge.EVENT_BUS.addListener(this::onServerStarted);
        MinecraftForge.EVENT_BUS.addListener(this::onServerStopping);
    }

    private void commonSetup(FMLCommonSetupEvent event) {
        Path gameDir = FMLPaths.GAMEDIR.get();
        String ip = "";
        Path props = gameDir.resolve("server.properties");
        if (Files.isRegularFile(props)) {
            Properties p = new Properties();
            try (Reader r = Files.newBufferedReader(props)) {
                p.load(r);
                ip = p.getProperty("server-ip", "");
            } catch (IOException e) {
                ip = "(unreadable: " + e.getMessage() + ")";
            }
        }
        List<String> problems = Guard.check(ip, gameDir.resolve(Guard.ALLOW_FILE), versionOf("computercraft"), versionOf("advancedperipherals"));
        if (!problems.isEmpty()) {
            String message = "t2control refuses to run: " + String.join("; ", problems);
            LOGGER.error(message);
            // an exception in common setup is a mod loading failure: the server does not start
            throw new IllegalStateException(message);
        }
        LOGGER.info("t2control loaded: local test server, allow file present, CC:Tweaked {} and Advanced Peripherals {} as expected",
                Guard.EXPECTED_CC_TWEAKED, Guard.EXPECTED_ADVANCED_PERIPHERALS);
    }

    private void onCommands(RegisterCommandsEvent event) {
        T2Commands.register(event.getDispatcher());
    }

    private void onServerStarted(ServerStartedEvent event) {
        server = event.getServer();
        Logs.open(FMLPaths.GAMEDIR.get().resolve("t2control"), () -> server == null ? -1L : server.getTickCount());
        LOGGER.info("t2control logs open under {} (radio and event logging are off until /t2 radio log on, /t2 events log on)",
                FMLPaths.GAMEDIR.get().resolve("t2control"));
    }

    private void onServerStopping(ServerStoppingEvent event) {
        Logs.close();
        server = null;
    }

    private static String versionOf(String modId) {
        return ModList.get().getModContainerById(modId).map(c -> c.getModInfo().getVersion().toString()).orElse(null);
    }
}
