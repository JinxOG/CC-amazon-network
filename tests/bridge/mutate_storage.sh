#!/bin/bash
# Mutation suite for acceptStorage in server.js.
#
# A test that cannot fail is worse than no test: it reports safety it never
# checked. Each entry here breaks one rule the suite claims to guard. Every one
# must be KILLED. A SURVIVED line means that assertion is decorative.
#
# Separator is ||| — see the note in test_storage.js before changing it.

cd "$(dirname "$0")" || exit 1
fails=0

run() {
  desc="$1"; mut="$2"
  outp=$(node test_storage.js --mutate "$mut" 2>&1)
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

run "timestamp guard removed" \
  'if (typeof ts !== '"'"'number'"'"' || !Number.isFinite(ts) || ts <= 0) {|||if (false) {'
run "array guard removed" \
  'if (!Array.isArray(list)) return|||if (false) return'
run "newest-wins removed" \
  'ts < state.storageTs|||false'
run "equal reading treated as stale" \
  'ts < state.storageTs|||ts <= state.storageTs'
run "source not recorded" \
  'state.storageSource = source;|||;'
run "timestamp not recorded" \
  'state.storageTs     = ts;|||;'
run "item count always zero" \
  'items: list.length|||items: 0'

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL MUTANTS KILLED"; else echo "$fails MUTANT(S) NOT KILLED"; fi
exit "$fails"
