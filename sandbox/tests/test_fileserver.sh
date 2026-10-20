#!/usr/bin/env bash
# File server checks. Run by test_fileserver.lua (so it is part of `sandbox/sim test`), or by hand.
# Prints "ok <name>" per passing check and "FAIL <name>" per failing one; exits non-zero on any failure.
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root" || exit 2
fails=0
ok()   { echo "ok $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
mkdir -p "$tmp/logs"
cat > "$tmp/state.json" <<'EOF'
{"turtles":{"node_1":{"status":"IDLE"}},"jobs":[],"version":"1.9.140","storage":[],"storageTs":0,"mineZones":[],"serverTime":1790067600000}
EOF
cat > "$tmp/logs/2026-09-22.txt" <<'EOF'
2026-09-22T08:00:00.000Z  server#1       INFO   boot ok
2026-09-22T08:00:01.000Z  node_1#1       INFO   [node_1][INFO] alpha marker
2026-09-22T08:00:02.000Z  node_1#2       WARN   [node_1][WARN] beta marker
2026-09-22T08:00:03.000Z  node_1#4       INFO   [node_1][INFO] gamma marker
EOF

# earlier days exist too: ack_loss looks back before its window
for d in 2026-09-18 2026-09-19 2026-09-20 2026-09-21; do
  echo "${d}T12:00:00.000Z  server#1       INFO   quiet day" > "$tmp/logs/$d.txt"
done

port="$(python -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
node sandbox/bridge/fileserver.js "$tmp" "$port" > "$tmp/server.out" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT

up=""
for _ in $(seq 1 50); do
  if curl -s "http://127.0.0.1:$port/ping" | grep -q '"ok":true'; then up=1; break; fi
  sleep 0.2
done
[ -n "$up" ] && ok "server starts" || { fail "server starts"; cat "$tmp/server.out"; exit 1; }

curl -s "http://127.0.0.1:$port/state" | grep -q '"node_1":{"status":"IDLE"}' && ok "state returns the fixture" || fail "state returns the fixture"

n="$(curl -s "http://127.0.0.1:$port/logs/2026-09-22?contains=marker&limit=10" | python -c 'import json,sys; d=json.load(sys.stdin); print(d["returned"])')"
[ "$n" = "3" ] && ok "logs contains filter" || fail "logs contains filter (got $n)"

n="$(curl -s "http://127.0.0.1:$port/logs/2026-09-22?level=WARN" | python -c 'import json,sys; d=json.load(sys.stdin); print(d["returned"], d["lines"][0]["source"])')"
[ "$n" = "1 node_1" ] && ok "logs level and source parse" || fail "logs level and source parse (got $n)"

v="$(curl -s "http://127.0.0.1:$port/logs/latest?audit=1&minLines=1" | python -c 'import json,sys; d=json.load(sys.stdin); print(d["verdict"], d["sources"]["node_1"]["missing"])')"
[ "$v" = "gaps 1" ] && ok "audit sees the missing sequence number" || fail "audit sees the missing sequence number (got $v)"

curl -s "http://127.0.0.1:$port/logs" | grep -q '"date":"2026-09-22"' && ok "log list" || fail "log list"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/update" -d '{}')"
[ "$code" = "405" ] && ok "writes are refused" || fail "writes are refused (got $code)"

curl -s "http://127.0.0.1:$port/" | grep -qi "<html" && ok "dashboard page is served" || fail "dashboard page is served"

# the dashboard's STALE badge compares updatedAt with the browser's clock: a freshly written state must read fresh
cat > "$tmp/state.json" <<'EOT'
{"turtles":{"node_1":{"role":"MINER","x":1950,"y":70,"z":-2620,"lastSeen":1790067590000},"node_2":{"role":"DELIVERY","x":160,"y":64,"z":-2800},"node_3":{"role":"SUPPORT","x":1960,"y":70,"z":-2615}},"jobs":[],"mineZones":{"j1":{"bounds":{"x1":1904,"z1":-2640,"x2":2000,"z2":-2608},"phase":"SURVEY","surveyDone":1,"surveyTotal":3}},"updatedAt":1790067599000,"serverTime":1790067600000}
EOT
age="$(curl -s "http://127.0.0.1:$port/state" | python -c 'import json,sys,time; d=json.load(sys.stdin); print(int(abs(time.time()*1000-d["updatedAt"])/1000), int(abs(time.time()*1000-d["turtles"]["node_1"]["lastSeen"])/1000))')"
set -- $age
[ "$1" -le 8 ] && [ "$2" -le 12 ] && ok "state timestamps read fresh while being written" || fail "state timestamps read fresh while being written (age $age)"

code="$(curl -s -o "$tmp/frame.html" -w '%{http_code}' "http://127.0.0.1:$port/dynmap-frame")"
if [ "$code" = "200" ] && grep -qi "<html" "$tmp/frame.html" && grep -q "not Dynmap" "$tmp/frame.html"; then ok "dynmap-frame is served"; else fail "dynmap-frame is served (got $code)"; fi

n="$(curl -s "http://127.0.0.1:$port/state" | node -e 'const m=require("./sandbox/bridge/map_model.js");let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const r=m.buildMapModel(JSON.parse(b));console.log(r.turtles.length,r.zones.length,r.zones[0].cells.filter(c=>c.state==="done").length)})')"
[ "$n" = "3 1 1" ] && ok "map model has one marker per turtle" || fail "map model has one marker per turtle (got $n)"

# loopback only
listen="$(netstat -ano 2>/dev/null | grep ":$port " | grep -i LISTEN | head -1)"
if echo "$listen" | grep -q "127.0.0.1:$port"; then ok "listens on 127.0.0.1 only"; else fail "listens on 127.0.0.1 only ($listen)"; fi

# the tools run against it through BRIDGE_URL, with no traceback
for tool in gate_check ack_loss; do
  out="$(BRIDGE_URL="http://127.0.0.1:$port" python tools/$tool.py 2026-09-22T00:00:00Z 2>&1)"
  if echo "$out" | grep -q "Traceback"; then fail "$tool completes against the fixture"; echo "$out" | tail -5
  elif echo "$out" | grep -q "127.0.0.1:$port\|192.168"; then fail "$tool names an address in its output"
  else ok "$tool completes against the fixture"; fi
done

# without BRIDGE_URL the tools still default to the live address (the line is read, never queried)
for tool in gate_check ack_loss; do
  grep -q 'os.environ.get("BRIDGE_URL", "http://192.168.86.35:3000")' tools/$tool.py && ok "$tool default address unchanged" || fail "$tool default address unchanged"
done

[ "$fails" = "0" ] && exit 0 || exit 1
