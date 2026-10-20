"""Finds the client-only mods a dedicated server will not load, by starting the server on a run folder until mod loading
succeeds, moving each mod the crash report names out of server/mods into server/mods-left-out (with the reason).
Dependencies that go missing because of a removal are removed the same way. Writes server/mods-left-out/LEFT_OUT.json.

    python sandbox/t2/trim_client_mods.py <run-id> [--max-rounds N]

Never touches the user's instance: only the copy under testserver/server.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import phase0  # noqa: E402
import prepare_run  # noqa: E402

ROOT = prepare_run.ROOT_DEFAULT


def attempt(run):
    for f in glob.glob(os.path.join(run, "crash-reports", "*")):
        os.remove(f)
    proc, log = phase0.start(run)
    started = time.time()
    outcome = "timeout"
    while time.time() - started < 600:
        time.sleep(2)
        if proc.poll() is not None:
            outcome = "exited"
            break
        text = open(os.path.join(run, "console.log"), encoding="utf8", errors="replace").read()
        if re.search(r"Done \([\d.]+s\)!", text):
            outcome = "started"
            break
        # a failed mod load can leave the JVM alive (a config watcher thread keeps it up), so look for the failure itself
        if "Failed to start the minecraft server" in text or glob.glob(os.path.join(run, "crash-reports", "*")):
            outcome = "failed"
            time.sleep(3)
            break
    if proc.poll() is None:
        proc.kill()
    proc.wait()
    log.close()
    return outcome


def mod_ids(mods_dir):
    """modId -> jar file name, read from each jar's META-INF/mods.toml."""
    import zipfile
    ids = {}
    for jar in glob.glob(os.path.join(mods_dir, "*.jar")):
        try:
            text = zipfile.ZipFile(jar).read("META-INF/mods.toml").decode("utf8", "replace")
        except (KeyError, zipfile.BadZipFile):
            continue
        for m in re.finditer(r'modId\s*=\s*"([^"]+)"', text):
            ids.setdefault(m.group(1), os.path.basename(jar))
    return ids


def culprits(run):
    out = {}
    ids = mod_ids(os.path.join(ROOT, "server", "mods"))
    for f in glob.glob(os.path.join(run, "crash-reports", "*")):
        text = open(f, encoding="utf8", errors="replace").read()
        for m in re.finditer(r"-- MOD (\S+) --\s+Details:\s+(?:Mod File: (\S[^\n]*)\n\s+)?(?:Failure message: )?([^\n]*)", text):
            jar = os.path.basename(m.group(2).strip()) if m.group(2) else ids.get(m.group(1))
            if jar:
                out[jar] = m.group(1) + ": " + m.group(3).strip()
        # missing dependencies are reported without a file: "Mod X requires Y" -> remove X
        for m in re.finditer(r"Mod ID: '([^']+)', Requested by: '([^']+)'", text):
            out.setdefault("REQ:" + m.group(2), "needs " + m.group(1))
    return out


def main():
    run = os.path.join(ROOT, "runs", sys.argv[1])
    rounds = int(sys.argv[sys.argv.index("--max-rounds") + 1]) if "--max-rounds" in sys.argv else 12
    mods = os.path.join(ROOT, "server", "mods")
    left = os.path.join(ROOT, "server", "mods-left-out")
    os.makedirs(left, exist_ok=True)
    record_path = os.path.join(left, "LEFT_OUT.json")
    record = json.load(open(record_path)) if os.path.exists(record_path) else {}
    for r in range(rounds):
        outcome = attempt(run)
        print("round", r + 1, outcome, flush=True)
        if outcome == "started":
            break
        bad = culprits(run)
        if not bad:
            print("no culprit found in the crash report; stopping")
            break
        moved = 0
        for jar, why in bad.items():
            if jar.startswith("REQ:"):
                print("   missing dependency:", jar, why)
                continue
            src = os.path.join(mods, jar)
            if os.path.exists(src):
                shutil.move(src, os.path.join(left, jar))
                record[jar] = why
                moved += 1
                print("   left out:", jar, "-", why[:120])
        if not moved:
            print("nothing movable; stopping")
            break
    json.dump(record, open(record_path, "w"), indent=1, sort_keys=True)
    print(len(record), "mods left out")


if __name__ == "__main__":
    main()
