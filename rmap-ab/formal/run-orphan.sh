#!/bin/sh
# Reproduce the PGCL #143 ORPHAN-PTE (structural three-way) model-checking
# results. Complements run.sh (the older refcount-only models).
# CBMC 6.8.0 ships inside Kani at ~/.kani/kani-0.67.0/bin.
set -e
export PATH="$HOME/.kani/kani-0.67.0/bin:$PATH"
echo "## cbmc: $(cbmc --version)"
echo

echo "===== 1. STRADDLE PTL-DROP model (the §4 hypothesis), faithful locking ====="
echo "      try_to_unmap_one straddle walk (PTL dropped mid-cluster) || deferred zap"
echo "      EXPECT: VERIFICATION SUCCESSFUL  (PTL-drop alone does NOT orphan)"
cbmc pgcl_orphan_pte.c --unwind 8 --unwinding-assertions \
  | grep -E 'VERIFICATION|failed'
echo

echo "===== 1b. minimal readable corroboration (straddle alone is safe) ====="
cbmc pgcl_orphan_pte_witness.c --unwind 6 | grep -E 'VERIFICATION|failed'
echo

echo "===== 2. FAULT re-add racing teardown (variant b) ====="
echo "      do_swap_page-style install (ref;rmap;set_ptes) || straddle teardown"
echo "      EXPECT: SUCCESSFUL with AND without folio_try_get (existence ref dominates)"
printf '   GUARD=1 (folio_try_get): '
cbmc pgcl_orphan_pte_v2.c -DGUARD=1 --unwind 8 --no-unwinding-assertions | grep -E 'VERIFICATION'
printf '   GUARD=0 (plain folio_get): '
cbmc pgcl_orphan_pte_v2.c -DGUARD=0 --unwind 8 --no-unwinding-assertions | grep -E 'VERIFICATION'
echo

echo "===== 3. UNIT-MISMATCH teardown (variant c) — THE ORPHAN ====="
echo "      one path counts PTE-clear and ref/rmap-drop in DIFFERENT units"
printf '   MISMATCH=0 (MMUPAGE-uniform, intended contract) — EXPECT SUCCESSFUL: '
cbmc pgcl_orphan_pte_v3.c -DMISMATCH=0 --unwind 8 --no-unwinding-assertions | grep -E 'VERIFICATION'
printf '   MISMATCH=1 (under-remove: clear all PTEs, drop 1 ref/cluster) — EXPECT FAILED (stuck ref): '
cbmc pgcl_orphan_pte_v3.c -DMISMATCH=1 --unwind 8 --no-unwinding-assertions | grep -E 'VERIFICATION'
printf '   MISMATCH=2 (over-drop: clear 1 PTE, drop PAGE_MMUCOUNT refs) — EXPECT FAILED (free-while-mapped): '
cbmc pgcl_orphan_pte_v3.c -DMISMATCH=2 --unwind 8 --no-unwinding-assertions | grep -E 'VERIFICATION'
echo

echo "===== the orphan schedule (MISMATCH=2 free-while-mapped instant) ====="
cbmc pgcl_orphan_pte_v3.c -DMISMATCH=2 --unwind 8 --no-unwinding-assertions \
  --trace --property put_refs.assertion.1 \
  | awk '/^State [0-9]+ .*thread [0-9]/{h=$0} /^  (refcount|freed|pte_present\[0|rmap_mmupage\[0)/{print h"  ==> "$0; h=""}' \
  | sed 's#file pgcl_orphan_pte_v3.c function [a-z_]* ##; s/ ([0-9a-fx ]*)//' | grep -v CPROVER_initialize
