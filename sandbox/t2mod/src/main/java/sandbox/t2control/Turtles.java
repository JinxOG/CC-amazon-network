package sandbox.t2control;

import java.io.File;
import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

import dan200.computercraft.api.turtle.ITurtleAccess;
import dan200.computercraft.shared.computer.core.ServerComputer;
import dan200.computercraft.shared.computer.core.ServerContext;
import dan200.computercraft.shared.turtle.blocks.TurtleBlockEntity;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtIo;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.entity.BlockEntity;

/** Turtle controls (spec section 6): move a turtle without a reboot, and save / restore one turtle (spec M4). */
public final class Turtles {
    private Turtles() {}

    private static final Pattern NAME = Pattern.compile("[A-Za-z0-9_-]{1,40}");

    private static ServerComputer computer(MinecraftServer server, int id) {
        for (ServerComputer c : ServerContext.get(server).registry().getComputers()) {
            if (c.getID() == id) return c;
        }
        return null;
    }

    private static TurtleBlockEntity turtle(ServerComputer c) {
        BlockEntity be = c.getLevel().getBlockEntity(c.getPosition());
        return be instanceof TurtleBlockEntity ? (TurtleBlockEntity) be : null;
    }

    private static Direction facing(String text) {
        if (text == null) return null;
        switch (text) {
            case "n": return Direction.NORTH;
            case "e": return Direction.EAST;
            case "s": return Direction.SOUTH;
            case "w": return Direction.WEST;
            default: return null;
        }
    }

    private static String err(String message) {
        return "{\"error\":\"" + message.replace("\\", "/").replace("\"", "'") + "\"}";
    }

    private static String dirName(Direction d) {
        return d.getName().substring(0, 1);
    }

    /** Moves a turtle to x, y, z through the call a turtle uses to move itself (its computer stays on), optionally turning it to face n/e/s/w. */
    public static String move(MinecraftServer server, int id, int x, int y, int z, String facing, long nowTick) {
        ServerComputer c = computer(server, id);
        if (c == null) return err("no loaded computer #" + id);
        TurtleBlockEntity t = turtle(c);
        if (t == null) return err("computer #" + id + " is not a turtle");
        Direction want = null;
        if (facing != null) {
            want = facing(facing);
            if (want == null) return err("facing must be n, e, s or w");
        }
        ITurtleAccess access = t.getAccess();
        BlockPos from = access.getPosition();
        ServerLevel level = c.getLevel();
        boolean ok = access.teleportTo(level, new BlockPos(x, y, z));
        if (!ok) return err("the turtle could not move to " + x + "," + y + "," + z + " (not loaded, or the block is not free)");
        if (want != null) access.setDirection(want);
        BlockPos now = access.getPosition();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("computer", id);
        args.put("from", from.getX() + "," + from.getY() + "," + from.getZ());
        args.put("to", now.getX() + "," + now.getY() + "," + now.getZ());
        args.put("facing", dirName(access.getDirection()));
        String result = "{\"ok\":true,\"pos\":[" + now.getX() + "," + now.getY() + "," + now.getZ() + "],\"facing\":\"" + dirName(access.getDirection()) + "\",\"on\":" + c.isOn() + "}";
        Logs.intervention("turtle_move", args, result);
        return result;
    }

    private static Path savesDir(Path gameDir) { return gameDir.resolve("t2control").resolve("saves"); }

    private static Path diskDir(MinecraftServer server, int id) { return ServerContext.get(server).storageDir().resolve("computer").resolve(Integer.toString(id)); }

    private static void copyTree(Path from, Path to) throws IOException {
        Files.createDirectories(to);
        Files.walkFileTree(from, new SimpleFileVisitor<>() {
            @Override public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) throws IOException {
                Files.createDirectories(to.resolve(from.relativize(dir).toString()));
                return FileVisitResult.CONTINUE;
            }
            @Override public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                Files.copy(file, to.resolve(from.relativize(file).toString()), StandardCopyOption.REPLACE_EXISTING);
                return FileVisitResult.CONTINUE;
            }
        });
    }

    private static void deleteTree(Path dir) throws IOException {
        if (!Files.exists(dir)) return;
        Files.walkFileTree(dir, new SimpleFileVisitor<>() {
            @Override public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException { Files.delete(file); return FileVisitResult.CONTINUE; }
            @Override public FileVisitResult postVisitDirectory(Path d, IOException e) throws IOException { Files.delete(d); return FileVisitResult.CONTINUE; }
        });
    }

    /** Saves a turtle: its block entity data (inventory, fuel, upgrades, facing, label) and its computer's disk folder, together. */
    public static String save(MinecraftServer server, Path gameDir, int id, String name) {
        if (!NAME.matcher(name).matches()) return err("name must be 1 to 40 letters, digits, _ or -");
        ServerComputer c = computer(server, id);
        if (c == null) return err("no loaded computer #" + id);
        TurtleBlockEntity t = turtle(c);
        if (t == null) return err("computer #" + id + " is not a turtle");
        Path dir = savesDir(gameDir).resolve(name);
        try {
            deleteTree(dir);
            Files.createDirectories(dir);
            CompoundTag tag = t.saveWithoutMetadata();
            CompoundTag wrapper = new CompoundTag();
            wrapper.put("be", tag);
            wrapper.putInt("computer", id);
            BlockPos p = c.getPosition();
            wrapper.putInt("x", p.getX());
            wrapper.putInt("y", p.getY());
            wrapper.putInt("z", p.getZ());
            wrapper.putString("facing", t.getDirection().getName());
            NbtIo.writeCompressed(wrapper, dir.resolve("state.nbt").toFile());
            Path disk = diskDir(server, id);
            if (Files.isDirectory(disk)) copyTree(disk, dir.resolve("disk"));
        } catch (IOException | RuntimeException e) {
            return err("save failed: " + e);
        }
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("computer", id);
        args.put("name", name);
        String result = "{\"ok\":true,\"saved\":\"" + name + "\",\"computer\":" + id + "}";
        Logs.intervention("turtle_save", args, result);
        return result;
    }

    /** Restores a saved turtle: shuts its computer down, puts it back where it was, puts back its data and disk folder, and turns it on. */
    public static String restore(MinecraftServer server, Path gameDir, String name, long nowTick) {
        if (!NAME.matcher(name).matches()) return err("name must be 1 to 40 letters, digits, _ or -");
        Path dir = savesDir(gameDir).resolve(name);
        File state = dir.resolve("state.nbt").toFile();
        if (!state.isFile()) return err("no save named " + name);
        try {
            CompoundTag wrapper = NbtIo.readCompressed(state);
            int id = wrapper.getInt("computer");
            ServerComputer c = computer(server, id);
            if (c == null) return err("computer #" + id + " is not loaded");
            TurtleBlockEntity t = turtle(c);
            if (t == null) return err("computer #" + id + " is not a turtle");
            c.shutdown();
            BlockPos want = new BlockPos(wrapper.getInt("x"), wrapper.getInt("y"), wrapper.getInt("z"));
            if (!c.getPosition().equals(want)) {
                if (!t.getAccess().teleportTo(c.getLevel(), want)) return err("could not move the turtle back to " + want.toShortString());
                c = computer(server, id);
                t = turtle(c);
            }
            t.clearContent();   // loading does not empty a slot that the saved data leaves out
            t.loadServer(wrapper.getCompound("be"));
            t.setChanged();
            Direction d = Direction.byName(wrapper.getString("facing"));
            if (d != null) t.getAccess().setDirection(d);
            Path disk = diskDir(server, id);
            Path saved = dir.resolve("disk");
            deleteTree(disk);
            if (Files.isDirectory(saved)) copyTree(saved, disk);
            c.turnOn();
            Map<String, Object> args = new LinkedHashMap<>();
            args.put("name", name);
            args.put("computer", id);
            String result = "{\"ok\":true,\"restored\":\"" + name + "\",\"computer\":" + id + "}";
            Logs.intervention("turtle_restore", args, result);
            return result;
        } catch (IOException | RuntimeException e) {
            return err("restore failed: " + e);
        }
    }
}
