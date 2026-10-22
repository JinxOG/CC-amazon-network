"""The project board, for the watcher and engineers: list cards with their bodies, move a card, append a note.

    python tools/board.py list [--status "Done - not server validated"] [--with-validation]
    python tools/board.py move <item-id> <status name>
    python tools/board.py note <item-id> "<text>"        appends a dated line to the card body

Cards are draft items on a PRIVATE board; the repo is public, so nothing here prints card text to a file.
Status names are matched exactly against the board's options; an unknown name is refused, never guessed.
"""
import datetime, json, re, subprocess, sys

GH = r"C:\Program Files\GitHub CLI\gh.exe"
PROJECT, NUMBER, OWNER_LOGIN = "PVT_kwHOByrE-s4BjIXS", "1", "JinxOG"
STATUS_FIELD = "PVTSSF_lAHOByrE-s4BjIXSzhh93j8"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def gh(*args):
    r = subprocess.run([GH, *args], capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        raise SystemExit(f"gh failed: {' '.join(args[:3])}...: {r.stderr.strip()}")
    return r.stdout


def graphql(query, **vars):
    args = ["api", "graphql", "-f", f"query={query}"]
    for k, v in vars.items():
        args += ["-f", f"{k}={v}"]
    return json.loads(gh(*args))["data"]


def status_options():
    d = graphql('query{ node(id:"%s"){ ... on ProjectV2SingleSelectField { options { id name } } } }' % STATUS_FIELD)
    return {o["name"]: o["id"] for o in d["node"]["options"]}


def items():
    # --limit is NOT optional: the default 30 silently hides newer cards (reference-project-board).
    return json.loads(gh("project", "item-list", NUMBER, "--owner", OWNER_LOGIN, "--limit", "500", "--format", "json"))["items"]


def body_of(item_id):
    d = graphql('query{ node(id:"%s"){ ... on ProjectV2Item { content { ... on DraftIssue { id body } } } } }' % item_id)
    c = (d["node"] or {}).get("content") or {}
    return c.get("id"), c.get("body", "")


def cmd_list(status=None, with_validation=False):
    for it in items():
        if status and it.get("status") != status:
            continue
        _, body = body_of(it["id"])
        # A real block starts a line with VALIDATION and has a Worked if: field. A card that merely
        # mentions "the VALIDATION block" in prose does not count.
        if with_validation and not (re.search(r"^VALIDATION", body, re.M) and "Worked if:" in body):
            continue
        print("=" * 100)
        print(f"ID      {it['id']}\nTITLE   {it.get('title')}\nSTATUS  {it.get('status')}\nOWNER   {it.get('owner', '-')}")
        print(body)


def cmd_move(item_id, status):
    opts = status_options()
    if status not in opts:
        raise SystemExit(f"unknown status {status!r}; the board has: {', '.join(opts)}")
    gh("project", "item-edit", "--id", item_id, "--project-id", PROJECT, "--field-id", STATUS_FIELD,
       "--single-select-option-id", opts[status])
    after = {i["id"]: i.get("status") for i in items()}.get(item_id)
    if after != status:
        raise SystemExit(f"move not confirmed: card shows {after!r}")
    print(f"moved {item_id} -> {status} (confirmed)")


def cmd_note(item_id, text):
    did, body = body_of(item_id)
    if not did:
        raise SystemExit("not a draft card; cannot edit its body")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    new = body.rstrip() + f"\n\n{stamp} {text}"
    graphql("mutation($id:ID!,$b:String!){ updateProjectV2DraftIssue(input:{draftIssueId:$id, body:$b}){ draftIssue { id } } }",
            id=did, b=new)
    print(f"noted on {item_id}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(2)
    if a[0] == "list":
        st = a[a.index("--status") + 1] if "--status" in a else None
        cmd_list(st, "--with-validation" in a)
    elif a[0] == "move" and len(a) == 3:
        cmd_move(a[1], a[2])
    elif a[0] == "note" and len(a) == 3:
        cmd_note(a[1], a[2])
    else:
        print(__doc__); sys.exit(2)
