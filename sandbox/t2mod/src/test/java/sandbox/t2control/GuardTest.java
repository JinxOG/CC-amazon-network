package sandbox.t2control;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class GuardTest {
    @TempDir
    Path dir;

    private Path allow(String text) throws Exception {
        Path f = dir.resolve(Guard.ALLOW_FILE);
        Files.writeString(f, text);
        return f;
    }

    @Test
    void everythingRightPasses() throws Exception {
        assertEquals(List.of(), Guard.check("127.0.0.1", allow("run cmp-1x\n"), "1.120.2", "0.7.46r"));
    }

    @Test
    void aServerThatIsNotLocalIsRefused() throws Exception {
        for (String ip : new String[] {"", "0.0.0.0", "192.168." + "86." + "35", null}) {
            List<String> p = Guard.check(ip, allow("run x"), "1.120.2", "0.7.46r");
            assertTrue(p.stream().anyMatch(s -> s.contains("not 127.0.0.1")), "ip " + ip);
        }
    }

    @Test
    void aMissingAllowFileIsRefused() {
        List<String> p = Guard.check("127.0.0.1", dir.resolve("nothing-here"), "1.120.2", "0.7.46r");
        assertTrue(p.stream().anyMatch(s -> s.contains("allow file")));
        assertTrue(Guard.check("127.0.0.1", null, "1.120.2", "0.7.46r").size() >= 1);
    }

    @Test
    void anAllowFileThatNamesNoRunIsRefused() throws Exception {
        assertTrue(Guard.check("127.0.0.1", allow(""), "1.120.2", "0.7.46r").size() >= 1);
        assertTrue(Guard.check("127.0.0.1", allow("run "), "1.120.2", "0.7.46r").size() >= 1);
        assertTrue(Guard.check("127.0.0.1", allow("whatever"), "1.120.2", "0.7.46r").size() >= 1);
    }

    @Test
    void aWrongCcTweakedVersionIsRefused() throws Exception {
        List<String> p = Guard.check("127.0.0.1", allow("run x"), "1.118.0", "0.7.46r");
        assertEquals(1, p.size());
        assertTrue(p.get(0).contains("CC:Tweaked is 1.118.0"));
    }

    @Test
    void aWrongOrMissingAdvancedPeripheralsIsRefused() throws Exception {
        assertEquals(1, Guard.check("127.0.0.1", allow("run x"), "1.120.2", "0.7.47").size());
        assertEquals(1, Guard.check("127.0.0.1", allow("run x"), "1.120.2", null).size());
        assertEquals(1, Guard.check("127.0.0.1", allow("run x"), null, "0.7.46r").size());
    }

    @Test
    void everyProblemIsReportedAtOnce() {
        assertEquals(4, Guard.check("10.0.0.5", null, "1.0", "1.0").size());
    }
}
