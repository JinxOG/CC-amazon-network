#!/usr/bin/env python3
"""Tests for tools/mail.py.

The first test is the defect W3 hit ten minutes after the mailbox opened: one
recipient closing a six-recipient memo emptied it out of all six inboxes,
including five engineers who had never read it. It fails against a single
shared status field.

    python tests/test_mail.py
"""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIL_PY = os.path.join(ROOT, "tools", "mail.py")

_failures = []


def run(tmp, *args):
    env = dict(os.environ, CLAUDE_PROJECT_DIR=tmp)
    p = subprocess.run([sys.executable, MAIL_PY] + list(args), env=env,
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else
                                                       " -- " + detail))
    if not cond:
        _failures.append(name)


def write(tmp, name, header, body="# body\n"):
    path = os.path.join(tmp, "docs", "mail", name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("---\n%s\n---\n\n%s" % (header.strip(), body))
    return path


BROADCAST = "2026-01-01-SPEC-OWNER-to-all-protocol.md"
BROADCAST_HEAD = """to: W1,W2,W3,W4,W5,W6
from: SPEC-OWNER
kind: info
subject: The protocol
date: 2026-01-01
status: open"""


def test_close_as_one_recipient_leaves_the_others_open(tmp):
    write(tmp, BROADCAST, BROADCAST_HEAD)
    code, out = run(tmp, "close", BROADCAST, "--as", "W3")
    check("close --as W3 succeeds", code == 0, out)
    code, out = run(tmp, "inbox", "W3")
    check("closed for W3", "no open mail" in out, out)
    for who in ("W1", "W2", "W4", "W5", "W6"):
        code, out = run(tmp, "inbox", who)
        check("still open for %s" % who, "has 1 open" in out, out)


def test_close_without_as_is_refused_on_multi_recipient(tmp):
    write(tmp, BROADCAST, BROADCAST_HEAD)
    code, out = run(tmp, "close", BROADCAST)
    check("refused without --as", code != 0, out)
    check("refusal names the recipients", "W1" in out and "--as" in out, out)
    code, out = run(tmp, "inbox", "W1")
    check("refusal changed nothing", "has 1 open" in out, out)


def test_close_all_closes_for_everyone(tmp):
    write(tmp, BROADCAST, BROADCAST_HEAD)
    code, out = run(tmp, "close", BROADCAST, "--all")
    check("--all succeeds", code == 0, out)
    check("--all says who it affects", "6 recipients" in out, out)
    for who in ("W1", "W6"):
        code, out = run(tmp, "inbox", who)
        check("closed for %s" % who, "no open mail" in out, out)


def test_single_recipient_needs_no_flag(tmp):
    name = "2026-01-01-W3-to-SPEC-OWNER-one.md"
    write(tmp, name, """to: SPEC-OWNER
from: W3
kind: request
subject: One reader
date: 2026-01-01
status: open""")
    code, out = run(tmp, "answer", name)
    check("single recipient answers without --as", code == 0, out)
    code, out = run(tmp, "inbox", "SPEC-OWNER")
    check("no longer open", "no open mail" in out, out)


def test_as_rejects_a_non_recipient(tmp):
    write(tmp, BROADCAST, BROADCAST_HEAD)
    code, out = run(tmp, "close", BROADCAST, "--as", "W9")
    check("--as W9 refused", code != 0, out)
    code, out = run(tmp, "inbox", "W1")
    check("nothing changed", "has 1 open" in out, out)


def test_open_brief_hides_only_the_reader_who_closed(tmp):
    write(tmp, BROADCAST, BROADCAST_HEAD)
    run(tmp, "close", BROADCAST, "--as", "W3")
    code, out = run(tmp, "open", "--brief")
    check("W3 gone from the summary", "  W3 " not in out, out)
    check("W1 still in the summary", "  W1 " in out, out)


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        print(fn.__name__)
        with tempfile.TemporaryDirectory() as tmp:
            fn(tmp)
    print("\n%d checks failed" % len(_failures) if _failures else "\nall green")
    return 1 if _failures else 0


if __name__ == "__main__":
    sys.exit(main())
