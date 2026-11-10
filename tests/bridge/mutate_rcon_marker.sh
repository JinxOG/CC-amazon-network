#!/bin/bash
# Mutation suite for initMarkerSet in server.js.
#
# A test that cannot fail is worse than no test: it reports safety it never
# checked. Each entry here breaks one behaviour test_rcon_marker.js claims to
# guard. Every one must be KILLED. A SURVIVED line means that assertion is
# decorative.
#
# The first entry restores the ACTUAL bug as it shipped until 2026-11-10 — an
# unreachable RCON logging "Marker set already exists (ok)". It must be killed,
# which is what makes this suite a proof rather than a decoration.
#
# Separator is ||| — see the note in test_rcon_marker.js before changing it.
#
# QUOTING. Anchors that span two source lines use ANSI-C quoting ($'...'),
# because in an ordinary double-quoted string \n stays a literal backslash-n
# and matches nothing. Two entries here were reported as unkilled mutants until
# that was fixed: a malformed mutation and a genuine hole look identical in the
# output, which is why the runner distinguishes MALFORMED from SURVIVED.

cd "$(dirname "$0")" || exit 1
fails=0

run() {
  desc="$1"; mut="$2"
  outp=$(node test_rcon_marker.js --mutate "$mut" 2>&1)
  if echo "$outp" | grep -q "MALFORMED"; then
    echo "  ERROR    $desc   <-- the mutation text does not match the source"
    fails=$((fails+1))
  elif echo "$outp" | grep -qE "[0-9]+ FAILED"; then
    echo "  KILLED   $desc"
  elif echo "$outp" | grep -q "ALL PASS"; then
    echo "  SURVIVED $desc   <-- assertion cannot detect this defect"
    fails=$((fails+1))
  else
    # A mutant that makes the code throw is a mutant the suite KILLED. Treating
    # a crash as a broken harness once threw away four genuine kills.
    echo "  KILLED   $desc   (mutant crashed)"
  fi
}

# ─── the original defect ────────────────────────────────────────────────────
run "THE SHIPPED BUG: unreachable RCON logs '(ok)'" \
  "markerSetReady = false;|||console.log('[RCON] Marker set already exists (ok)'); return;"

# ─── the failure branch ─────────────────────────────────────────────────────
run "failure branch goes silent" \
  "console.warn('[RCON] marker set|||void (' [RCON] marker set"
run "failure branch drops the underlying error" \
  "+ ((e2 && e2.message) || e2));|||);"
run "failure branch warns at log level instead of warn" \
  "console.warn('[RCON] marker set|||console.log('[RCON] marker set"
run "failure branch leaves the ready flag alone" \
  "markerSetReady = false;|||;"
run "failure branch claims ready" \
  "markerSetReady = false;|||markerSetReady = true;"

# ─── the healthy paths ──────────────────────────────────────────────────────
run "updateset is never attempted after a rejected addset" \
  'await rcon(`dmarker updateset id:${CFG.dynmap.set} label:Turtles hidebydefault:false`);|||;'
run "addset success does not record ready" \
  $'        markerSetReady = true;\n        console.log|||        console.log'
run "update path does not record ready" \
  $'            markerSetReady = true;\n            console.log|||            console.log'

# ─── the unknown state ──────────────────────────────────────────────────────
run "ready flag defaults to healthy instead of unknown" \
  "let markerSetReady = null;|||let markerSetReady = true;"

# ─── the boot-safety property ───────────────────────────────────────────────
run "the failure branch rethrows, breaking the unawaited boot call" \
  "markerSetReady = false;|||markerSetReady = false; throw e2;"

echo
if [ "$fails" -eq 0 ]; then echo "all mutants killed"; else echo "$fails mutant(s) not killed"; fi
exit "$fails"
