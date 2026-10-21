package sandbox.t2control;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * The load guard (spec section 5.1): decides whether this server is the local T2 test server. Plain Java so it can be
 * unit tested; the mod calls it at start-up and refuses to run when it returns any problem.
 */
public final class Guard {
    /** The versions the Mixins are written against (spec section 4). */
    public static final String EXPECTED_CC_TWEAKED = "1.120.2";
    public static final String EXPECTED_ADVANCED_PERIPHERALS = "0.7.46r";
    /** The allow file written by sandbox/t2/run.py with the run id. */
    public static final String ALLOW_FILE = "t2control.allow";

    private Guard() {}

    /**
     * @param serverIp   the server-ip from server.properties ("" when unset)
     * @param allowFile  the allow file path (it must exist and name a run)
     * @param ccVersion  the loaded CC:Tweaked version, or null when it is not loaded
     * @param apVersion  the loaded Advanced Peripherals version, or null when it is not loaded
     * @return every reason the mod must not run; empty when all checks pass
     */
    public static List<String> check(String serverIp, Path allowFile, String ccVersion, String apVersion) {
        List<String> problems = new ArrayList<>();
        if (!"127.0.0.1".equals(serverIp == null ? "" : serverIp.trim())) {
            problems.add("server-ip is '" + serverIp + "', not 127.0.0.1: this is not a local test server");
        }
        if (allowFile == null || !Files.isRegularFile(allowFile)) {
            problems.add("the allow file " + ALLOW_FILE + " is missing: only sandbox/t2/run.py may start this server");
        } else {
            try {
                String text = Files.readString(allowFile).trim();
                if (!text.startsWith("run ") || text.length() <= 4) {
                    problems.add("the allow file " + ALLOW_FILE + " does not name a run (expected 'run <id>')");
                }
            } catch (Exception e) {
                problems.add("the allow file " + ALLOW_FILE + " cannot be read: " + e.getMessage());
            }
        }
        if (ccVersion == null) {
            problems.add("CC:Tweaked is not loaded");
        } else if (!EXPECTED_CC_TWEAKED.equals(ccVersion)) {
            problems.add("CC:Tweaked is " + ccVersion + ", this mod is written for " + EXPECTED_CC_TWEAKED);
        }
        if (apVersion == null) {
            problems.add("Advanced Peripherals is not loaded");
        } else if (!EXPECTED_ADVANCED_PERIPHERALS.equals(apVersion)) {
            problems.add("Advanced Peripherals is " + apVersion + ", this mod is written for " + EXPECTED_ADVANCED_PERIPHERALS);
        }
        return problems;
    }
}
