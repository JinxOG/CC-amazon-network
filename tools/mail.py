#!/usr/bin/env python3
"""Engineer mailbox for Turtle OS.

Messages live in docs/mail/ as markdown with a small header block. This script
is the only thing that reads or writes that header, so the format cannot drift.

  python tools/mail.py inbox W6          what is open and addressed to W6
  python tools/mail.py open              everything open, grouped by recipient
  python tools/mail.py open --brief      one screen, for the session-start hook
  python tools/mail.py new --to W6 --from W3 --kind request --subject "..."
  python tools/mail.py answer <file> [--as W3]   mark answered, for you only
  python tools/mail.py close <file> [--as W3]    mark closed, for you only
  python tools/mail.py close <file> --all        close it for every recipient
  python tools/mail.py baton             who holds the baton
  python tools/mail.py who               the session address book

Exit status is always 0 unless a command genuinely failed: the hook must never
turn a missing folder into a startup error.
"""
import argparse
import datetime as _dt
import os
import re
import sys

ROOT = os.environ.get("CLAUDE_PROJECT_DIR") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
MAIL = os.path.join(ROOT, "docs", "mail")
KINDS = ("request", "ruling", "info", "reply")
STATUSES = ("open", "answered", "closed")
HEADER_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.S)


def _read(path):
    """Return (header dict, subject) or None when the file has no header."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    m = HEADER_RE.match(text)
    if not m:
        return None
    head = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            head[k.strip().lower()] = v.strip()
    body = text[m.end():].lstrip()
    subject = head.get("subject") or ""
    if not subject:
        for line in body.splitlines():
            if line.strip():
                subject = line.lstrip("# ").strip()
                break
    return head, subject


def _messages():
    if not os.path.isdir(MAIL):
        return []
    out = []
    for name in sorted(os.listdir(MAIL)):
        if not name.endswith(".md") or name.upper().startswith("README"):
            continue
        parsed = _read(os.path.join(MAIL, name))
        if parsed:
            head, subject = parsed
            out.append((name, head, subject))
    return out


def _recipients(head):
    return [p.strip().upper() for p in head.get("to", "").split(",") if p.strip()]


def _status_map(head):
    """Status per recipient.

    `status: open` means open for everyone. `status: W1=open,W3=answered`
    carries one state per reader -- because a six-recipient memo marked closed
    by one reader used to vanish from the other five inboxes, which happened
    ten minutes after this mailbox opened.
    """
    raw = head.get("status", "open").strip()
    people = _recipients(head) or ["?"]
    if "=" not in raw:
        return dict.fromkeys(people, raw.lower() or "open")
    out = dict.fromkeys(people, "open")
    for pair in raw.split(","):
        if "=" in pair:
            who, _, st = pair.partition("=")
            out[who.strip().upper()] = st.strip().lower()
    return out


def _render_status(smap, people):
    values = {smap.get(w, "open") for w in people}
    if len(values) == 1:
        return values.pop()
    return ",".join("%s=%s" % (w, smap.get(w, "open")) for w in people)


def _is_open(head, who=None):
    smap = _status_map(head)
    if who:
        return smap.get(who.upper(), "open") == "open"
    return any(v == "open" for v in smap.values())


def cmd_inbox(args):
    who = args.who.upper()
    rows = [(n, h, s) for n, h, s in _messages()
            if who in _recipients(h) and _is_open(h, who)]
    if not rows:
        print("%s: no open mail." % who)
        return
    print("%s has %d open:" % (who, len(rows)))
    for name, head, subject in rows:
        print("  [%s] from %s - %s" % (head.get("kind", "?"),
                                       head.get("from", "?"), subject))
        print("      docs/mail/%s" % name)


def cmd_open(args):
    rows = [(n, h, s) for n, h, s in _messages() if _is_open(h)]
    if not rows:
        print("Mail: nothing open.")
        return
    by_to = {}
    for name, head, subject in rows:
        for who in _recipients(head) or ["?"]:
            if _is_open(head, who):
                by_to.setdefault(who, []).append((name, head, subject))
    if args.brief:
        print("Mail - %d open. `python tools/mail.py inbox <W>` for yours."
              % len(rows))
        for who in sorted(by_to):
            items = by_to[who]
            first = items[0][2][:60]
            extra = "" if len(items) == 1 else " (+%d more)" % (len(items) - 1)
            print("  %-4s %d - %s%s" % (who, len(items), first, extra))
        return
    for who in sorted(by_to):
        print("%s:" % who)
        for name, head, subject in by_to[who]:
            print("  [%s] from %s - %s" % (head.get("kind", "?"),
                                           head.get("from", "?"), subject))
            print("      docs/mail/%s" % name)


def cmd_new(args):
    kind = args.kind.lower()
    if kind not in KINDS:
        sys.exit("kind must be one of: %s" % ", ".join(KINDS))
    date = _dt.date.today().isoformat()
    slug = re.sub(r"[^a-z0-9]+", "-", args.subject.lower()).strip("-")[:60]
    name = "%s-%s-to-%s-%s.md" % (date, args.sender.upper(),
                                  args.to.upper().replace(",", "-"), slug)
    path = os.path.join(MAIL, name)
    if os.path.exists(path):
        sys.exit("already exists: docs/mail/%s" % name)
    os.makedirs(MAIL, exist_ok=True)
    header = ["---",
              "to: %s" % args.to.upper(),
              "from: %s" % args.sender.upper(),
              "kind: %s" % kind,
              "subject: %s" % args.subject,
              "date: %s" % date]
    if args.re:
        header.append("re: %s" % args.re)
    header += ["status: open", "---", "", "# %s" % args.subject, ""]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(header))
    print("docs/mail/%s" % name)


def _set_status(path, status, who=None, everyone=False):
    """Mark one reader's copy, or with everyone=True the whole message.

    A multi-recipient message needs --as or --all. Marking your own copy must
    not take the message out of five other inboxes: that happened to a binding
    protocol memo ten minutes after this mailbox opened, and a single shared
    status field is what allowed it.
    """
    name = os.path.basename(path)
    full = path if os.path.isabs(path) else os.path.join(MAIL, name)
    if not os.path.exists(full):
        sys.exit("no such message: %s" % name)
    with open(full, encoding="utf-8") as fh:
        text = fh.read()
    m = HEADER_RE.match(text)
    if not m:
        sys.exit("%s has no header" % name)
    parsed = _read(full)
    head_dict = parsed[0] if parsed else {}
    people = _recipients(head_dict)
    smap = _status_map(head_dict)

    if everyone:
        if len(people) > 1:
            print("closing for all %d recipients: %s"
                  % (len(people), ", ".join(people)))
        smap = dict.fromkeys(people or ["?"], status)
    else:
        if who:
            who = who.upper()
            if people and who not in people:
                sys.exit("%s is not a recipient of %s (to: %s)"
                         % (who, name, ", ".join(people)))
        elif len(people) > 1:
            sys.exit("%s has %d recipients (%s). "
                     "Mark your own copy with --as <W>, or mark it for "
                     "everyone with --all." % (name, len(people),
                                               ", ".join(people)))
        else:
            who = people[0] if people else "?"
        smap[who] = status

    rendered = _render_status(smap, people or ["?"])
    head = m.group(1)
    if re.search(r"^status:", head, re.M):
        head = re.sub(r"^status:.*$", "status: %s" % rendered, head, flags=re.M)
    else:
        head += "\nstatus: %s" % rendered
    with open(full, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("---\n%s\n---\n%s" % (head, text[m.end():]))
    still = [w for w in people if smap.get(w, "open") == "open"]
    note = " (still open for %s)" % ", ".join(still) if still else ""
    print("%s: %s%s" % (name, rendered, note))


def cmd_answer(args):
    _set_status(args.file, "answered", args.as_who, args.everyone)


def cmd_close(args):
    _set_status(args.file, "closed", args.as_who, args.everyone)


def _show_file(filename, missing):
    path = os.path.join(MAIL, filename)
    if not os.path.exists(path):
        print(missing)
        return
    with open(path, encoding="utf-8") as fh:
        sys.stdout.write(fh.read())


def cmd_baton(args):
    _show_file("BATON.md", "No BATON.md - ask the head engineer who holds it.")


def cmd_who(args):
    _show_file("ADDRESS-BOOK.md",
               "No ADDRESS-BOOK.md - add your own row when you next wake.")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("inbox"); s.add_argument("who"); s.set_defaults(fn=cmd_inbox)
    s = sub.add_parser("open"); s.add_argument("--brief", action="store_true")
    s.set_defaults(fn=cmd_open)
    s = sub.add_parser("new")
    s.add_argument("--to", required=True)
    s.add_argument("--from", dest="sender", required=True)
    s.add_argument("--kind", required=True)
    s.add_argument("--subject", required=True)
    s.add_argument("--re", default="")
    s.set_defaults(fn=cmd_new)
    for verb, fn in (("answer", cmd_answer), ("close", cmd_close)):
        s = sub.add_parser(verb)
        s.add_argument("file")
        s.add_argument("--as", dest="as_who", default="",
                       help="mark only this recipient's copy")
        s.add_argument("--all", dest="everyone", action="store_true",
                       help="mark it for every recipient")
        s.set_defaults(fn=fn)
    sub.add_parser("baton").set_defaults(fn=cmd_baton)
    sub.add_parser("who").set_defaults(fn=cmd_who)
    args = p.parse_args()
    if not getattr(args, "fn", None):
        p.print_help()
        return
    args.fn(args)


if __name__ == "__main__":
    main()
