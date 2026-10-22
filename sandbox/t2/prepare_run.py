"""Makes a disposable T2 run folder from a world copy: a working copy of the world, the server's mods and libraries
(junctions, read-only use), configs, server.properties and eula.txt, and the ComputerCraft HTTP rules rewritten so the
fleet can reach only the local bridge and GitHub's raw host. The tool refuses to leave a run whose rules differ.

    python sandbox/t2/prepare_run.py <run-id> <world-dir> [--root G:/TurtleOS-Sandbox/testserver]

The user's Modrinth instance is never written to (nothing here touches it). The Mojang EULA is accepted for this
private server with the user's say-so (2026-10-20).
"""
import os
import re
import secrets
import shutil
import subprocess
import sys

ROOT_DEFAULT = "G:/TurtleOS-Sandbox/testserver"
BRIDGE_PORT = 3000
ALLOWED_RULES = (
    '[[http.rules]]\n\t\thost = "127.0.0.1"\n\t\tport = %d\n\t\taction = "allow"\n\n' % BRIDGE_PORT
    + '\t[[http.rules]]\n\t\thost = "raw.githubusercontent.com"\n\t\taction = "allow"\n\n'
    + '\t[[http.rules]]\n\t\thost = "$private"\n\t\taction = "deny"\n\n'
    + '\t[[http.rules]]\n\t\thost = "*"\n\t\taction = "deny"\n'
)


def rewrite_http_rules(toml_text):
    """Replaces every [[http.rules]] block in the [http] section with the safe four."""
    first = toml_text.index("[[http.rules]]")
    # the rules are the last thing in the [http] section; anything after the last rule block that starts a new
    # top-level section ([something]) is kept
    tail = re.search(r"\n\[(?!\[http\.rules)[^\]]+\]", toml_text[first:])
    end = first + tail.start() + 1 if tail else len(toml_text)
    return toml_text[:first] + ALLOWED_RULES + "\n" + toml_text[end:]


def rules_are_safe(toml_text):
    """True only if the HTTP rules allow exactly 127.0.0.1:<bridge port> and raw.githubusercontent.com and deny the
    rest, including $private. Used before every start."""
    blocks = re.findall(r"\[\[http\.rules\]\](.*?)(?=\n\s*\[|\Z)", toml_text, flags=re.S)
    rules = []
    for b in blocks:
        host = re.search(r'host\s*=\s*"([^"]*)"', b)
        action = re.search(r'action\s*=\s*"([^"]*)"', b)
        port = re.search(r"port\s*=\s*(\d+)", b)
        rules.append((host.group(1) if host else None, int(port.group(1)) if port else None, action.group(1) if action else None))
    return rules == [("127.0.0.1", BRIDGE_PORT, "allow"), ("raw.githubusercontent.com", None, "allow"),
                     ("$private", None, "deny"), ("*", None, "deny")]


MOD_ID = "t2control"


def is_t2control_jar(path):
    """True when the jar is the T2 control mod, by file name or by the mod id in its mods.toml."""
    if os.path.basename(path).lower().startswith(MOD_ID):
        return True
    try:
        import zipfile
        with zipfile.ZipFile(path) as z:
            text = z.read("META-INF/mods.toml").decode("utf8", "replace")
        return re.search(r'modId\s*=\s*"%s"' % MOD_ID, text) is not None
    except Exception:  # noqa: BLE001 - not a readable mod jar
        return False


def default_scan_dirs(root=ROOT_DEFAULT):
    """Every mods folder the control mod must NOT be in: the user's Modrinth instances (the sync program shares them with the
    live server) and any test-server folder other than the one T2 runs from."""
    dirs = []
    profiles = os.path.expandvars(r"%APPDATA%\ModrinthApp\profiles")
    if os.path.isdir(profiles):
        for name in os.listdir(profiles):
            dirs.append(os.path.join(profiles, name, "mods"))
    for name in os.listdir(root) if os.path.isdir(root) else []:
        if name.startswith("server") and name != "server":
            dirs.append(os.path.join(root, name, "mods"))
    return dirs


def mod_found_outside(scan_dirs=None, root=ROOT_DEFAULT):
    """The jars of the control mod found in folders where it must not be (the placement guard, spec section 5.2)."""
    found = []
    for d in scan_dirs if scan_dirs is not None else default_scan_dirs(root):
        if os.path.isdir(d):
            for name in os.listdir(d):
                if name.lower().endswith(".jar") and is_t2control_jar(os.path.join(d, name)):
                    found.append(os.path.join(d, name))
    return found


def check_placement(scan_dirs=None, root=ROOT_DEFAULT):
    found = mod_found_outside(scan_dirs, root)
    if found:
        raise SystemExit("refusing to start: the T2 control mod is outside the test server's mods folder: " + "; ".join(found))


def junction(link, target):
    subprocess.run(["cmd", "/c", "mklink", "/J", link.replace("/", "\\"), target.replace("/", "\\")], check=True,
                   stdout=subprocess.DEVNULL)


def prepare(run_id, world_dir, root=ROOT_DEFAULT, ram="6G", server_port=25566, rcon_port=25576):
    check_placement(root=root)
    run = os.path.join(root, "runs", run_id)
    if os.path.exists(run):
        raise SystemExit("run folder exists: " + run)
    server = os.path.join(root, "server")
    os.makedirs(run)
    shutil.copytree(world_dir, os.path.join(run, "world"))
    for name in ("config", "defaultconfigs", "kubejs"):
        shutil.copytree(os.path.join(server, name), os.path.join(run, name))
    junction(os.path.join(run, "mods"), os.path.join(server, "mods"))
    junction(os.path.join(run, "libraries"), os.path.join(server, "libraries"))
    cc = os.path.join(run, "world", "serverconfig", "computercraft-server.toml")
    with open(cc, encoding="utf8") as f:
        text = f.read()
    text = rewrite_http_rules(text)
    with open(cc, "w", encoding="utf8", newline="\n") as f:
        f.write(text)
    if not rules_are_safe(text):
        raise SystemExit("refusing: the HTTP rules in " + cc + " are not the safe set")
    password = secrets.token_hex(8)
    props = {
        "level-name": "world", "online-mode": "false", "server-port": str(server_port), "server-ip": "127.0.0.1",
        "enable-rcon": "true", "rcon.port": str(rcon_port), "rcon.password": password, "broadcast-rcon-to-ops": "false",
        "motd": "SakuraPack T2 test server (local)", "white-list": "false", "spawn-protection": "0",
        "max-tick-time": "-1", "view-distance": "8", "simulation-distance": "8", "enable-command-block": "true",
        "allow-flight": "true", "sync-chunk-writes": "false",
    }
    with open(os.path.join(run, "server.properties"), "w", newline="\n") as f:
        f.write("".join("%s=%s\n" % kv for kv in props.items()))
    with open(os.path.join(run, "eula.txt"), "w") as f:
        f.write("eula=true\n")
    with open(os.path.join(run, "user_jvm_args.txt"), "w") as f:
        f.write("-Xms2G\n-Xmx%s\n" % ram)
    with open(os.path.join(run, "t2control.allow"), "w") as f:   # the control mod refuses to run without it (spec 5.1)
        f.write("run %s" % run_id + chr(10))
    with open(os.path.join(run, "rcon.txt"), "w") as f:
        f.write("127.0.0.1 %d %s\n" % (rcon_port, password))
    return run


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = ROOT_DEFAULT
    if "--root" in sys.argv:
        root = sys.argv[sys.argv.index("--root") + 1]
        args = [a for a in args if a != root]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    print(prepare(args[0], args[1], root))
