# T2 control mod, phase M0: toolchain, loading mod, guards

Written 2026-10-21 by the sandbox builder. Spec: `2026-10-20-t2-control-mod-design.md`. Downloads (user's OK given to me in
chat, 2026-10-20): Temurin JDK 17.0.20.1 (sha256 matched the one Adoptium publishes), the official Forge 1.20.1-47.4.10 MDK
(sha1 matched Forge's), and the Gradle 8.8 / ForgeGradle / Forge / Minecraft build dependencies into
`G:\TurtleOS-Sandbox\gradle` (Gradle home, the build output `t2mod-build/` and the project cache are on G: too; the repo holds
source only).

## What was built

- `sandbox/t2mod/`: a Gradle project from the MDK. `Guard.java` (plain Java: the checks), `T2Control.java` (the `@Mod`: runs the
  guard in common setup and throws, so the server does not start, when it fails), `GuardTest.java` (7 JUnit tests). Server-only
  declaration (`displayTest="IGNORE_SERVER_VERSION"`, dependency sides SERVER). Builds with
  `JAVA_HOME=G:/TurtleOS-Sandbox/toolchain/jdk-17.0.20.1+1 GRADLE_USER_HOME=G:/TurtleOS-Sandbox/gradle ./gradlew.bat build`; the
  jar `t2control-0.1.0.jar` is copied to `G:\TurtleOS-Sandbox\testserver\server\mods\` and nowhere else.
- The load guard (spec 5.1): the server stops at start-up unless `server-ip` is `127.0.0.1`, a file `t2control.allow` naming a
  run (`run <id>`) is in the server folder (`prepare_run.py` writes it), and CC:Tweaked is `1.120.2` and Advanced Peripherals
  `0.7.46r`. It reports every failed check at once.
- The placement guard (spec 5.2): `prepare_run.check_placement()`, called at the start of every `prepare`, refuses to start a run
  if a jar named `t2control*` or containing the mod id `t2control` is in any of the user's Modrinth instances' `mods` folders or
  in any `server-*` folder other than `server\`.

## Proof (`sandbox/t2/prove_mod.py m0`, runs `m0-base`, `m0-with`)

| Proof | Result |
|---|---|
| the mod loads on a run started by `run.py` | **proved**: `t2control loaded: local test server, allow file present, CC:Tweaked 1.120.2 and Advanced Peripherals 0.7.46r as expected` |
| cost with the mod loaded and everything off (bar: within 2%) | **proved**: mean tick time 7.96 ms without the mod (18 samples), 7.93 ms with it (18 samples), -0.4% (both runs with the fleet booted and idle at 1x) |
| refuses to start without the allow file | **proved**: `t2control refuses to run: the allow file t2control.allow is missing: only sandbox/t2/run.py may start this server`, no "Done" |
| refuses to start with `server-ip` not 127.0.0.1 | **proved**: `server-ip is '0.0.0.0', not 127.0.0.1`; the same run with the ip put back starts (so the refusal was the guard). The first attempt was fooled by a crash report left by the step before; the proof now clears it |
| `run.py` refuses when the jar is in another mods folder | **proved** with a real copy placed in `server-47410\mods` (refused, named); with it removed the guard passes; the user's instances hold no copy |
| refuses with a wrong CC:Tweaked or Advanced Peripherals version | **unit-tested only** (JUnit and no live run: the live server has exactly the right versions; a live proof would need a second CC:Tweaked jar) |

Also checked in `test_t2_rules.py` (in `sandbox/sim test`): the placement guard by file name, by mod id under another name, an
ordinary mod passing, a missing folder passing, and that the user's real instances hold no copy now (12 tests in all).

## Not done in M0 / notes

- The control commands, logs and faults are M1 onwards. M0's mod has no behaviour beyond the guard.
- Forge deprecation warning: `FMLJavaModLoadingContext.get()` is marked for removal in this Forge; it works on 47.4.10.
- Sampling noise: the mean tick time at 1x with the idle fleet was about 8 ms in this A/B (it was about 5 ms in the 1x job
  runs); the 2% bar is met on the means but the samples vary by 10-20% one to one, so M1's cost proof uses longer runs.
