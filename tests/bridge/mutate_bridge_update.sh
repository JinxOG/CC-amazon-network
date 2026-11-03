#!/bin/bash
# Mutation suite for mergeTurtleSnapshot and updateAllParams in server.js.
#
# A test that cannot fail is worse than no test: it reports safety it never
# checked. Every mutant here must be KILLED. A SURVIVED line means that
# assertion is decorative.
#
# The first mutant is the important one: it restores the ORIGINAL behaviour —
# a previous entry's fields surviving into the new snapshot — so a kill is the
# red-before-green proof that this suite detects the bug W3 reported, not just
# that the new code is self-consistent.
#
# Separator is ||| — see the note in test_bridge_update.js before changing it.

cd "$(dirname "$0")" || exit 1
fails=0

run() {
  desc="$1"; mut="$2"
  outp=$(node test_bridge_update.js --mutate "$mut" 2>&1)
  if echo "$outp" | grep -q "HARNESS ERROR"; then
    echo "  ERROR    $desc   <-- mutant did not compile; the mutation is malformed"
    echo "$outp" | grep "HARNESS ERROR" | sed 's/^/             /'
    fails=$((fails+1))
  elif echo "$outp" | grep -q "FAILURE(S)"; then
    echo "  KILLED   $desc"
  else
    echo "  SURVIVED $desc   <-- assertion cannot detect this defect"
    fails=$((fails+1))
  fi
}

run "THE OLD BUG: stale fields survive the merge" \
  'out[id] = { ...data, lastSeen: now };|||out[id] = { needsHands: "loader_outstanding", blockReason: "loader_outstanding", jobId: "job_0121", ...data, lastSeen: now };'
run "lastSeen no longer stamped" \
  'out[id] = { ...data, lastSeen: now };|||out[id] = { ...data };'
run "the incoming payload is mutated in place" \
  'out[id] = { ...data, lastSeen: now };|||(data.lastSeen = now, out[id] = data);'
run "a missing payload is no longer tolerated" \
  'Object.entries(incoming || {})|||Object.entries(incoming)'
run "commit match is unanchored" \
  'test(ref)|||test("x" + ref + "x")'
run "uppercase hex accepted" \
  'ref = String(sha|||ref = String(sha).toLowerCase() + String(sha'
run "trailing newline not trimmed" \
  '.trim();|||;'

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL MUTANTS KILLED"; else echo "$fails MUTANT(S) NOT KILLED"; fi
exit "$fails"
