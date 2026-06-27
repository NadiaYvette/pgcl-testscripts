#!/bin/sh
# Reproduce the PGCL #143 free-while-mapped model-checking results.
# CBMC 6.8.0 ships inside Kani at ~/.kani/kani-0.67.0/bin (the ~48GB job).
set -e
export PATH="$HOME/.kani/kani-0.67.0/bin:$PATH"
echo "## cbmc: $(cbmc --version)"
echo
echo "===== 1. THE BUG: naive non-atomic protocol  (expect VERIFICATION FAILED) ====="
cbmc pgcl_cluster.c --unwind 2 | grep -E 'assertion .*pte\[0\]|VERIFICATION'
echo
echo "===== 2. atomic refcount alone is NOT enough (expect VERIFICATION FAILED) ====="
cbmc pgcl_cluster_atomic.c --unwind 2 | grep -E 'VERIFICATION|failed'
echo
echo "===== 3. folio_try_get (inc-unless-zero) + existence ref IS safe (expect SUCCESSFUL) ====="
cbmc pgcl_cluster_tryget.c --unwind 2 | grep -E 'VERIFICATION|failed'
echo
echo "===== counterexample interleaving for the main bug ====="
cbmc pgcl_cluster.c --unwind 2 --trace --property main.assertion.4 \
  | awk '/^State [0-9]+ .*thread [0-9]/{h=$0} /^  (refcount|freed|pte\[0|mapcount\[0)/{print h"  ==> "$0; h=""}' \
  | sed 's#file pgcl_cluster.c function main ##; s/ ([01 ]*)//' | grep -v CPROVER_initialize
