#!/bin/sh
# surf-tlb: CBMC TLB/flush-coherence models for PGCL #143.
#
# Two models, single-CPU (-smp1), explicit nondeterministic schedule:
#   pgcl_tlb_flush.c          — immediate flush_tlb_range path (zap/munmap +
#                               non-batched reclaim).  BUG knob = the range calc.
#   pgcl_tlb_reclaim_batch.c  — the x86 DEFERRED reclaim path actually taken by
#                               #143 (TTU_BATCH_FLUSH).  ARCH_FULL/WRONG_RANGE knobs.
#
# Expectation summary (the FINDINGS):
#   faithful kernel          -> VERIFICATION SUCCESSFUL  (no stale entry survives)
#   broken range variants    -> VERIFICATION FAILED      (assertion has teeth)
#   x86 deferred (FULL flush) -> SUCCESSFUL even with a wrong recorded range.
set -u
CBMC="${CBMC:-$HOME/.kani/kani-0.67.0/bin/cbmc}"
DIR="$(cd "$(dirname "$0")" && pwd)"
UNWIND="${UNWIND:-13}"                 # must be > NSTEPS (default 12)
COMMON="--unwind $UNWIND --unwinding-assertions"

run() {
	label="$1"; shift
	src="$1"; shift
	printf '%-58s ' "$label"
	out="$("$CBMC" "$DIR/$src" "$@" $COMMON 2>&1)"
	v="$(printf '%s\n' "$out" | grep -Eo 'VERIFICATION (SUCCESSFUL|FAILED)' | head -1)"
	u="$(printf '%s\n' "$out" | grep -c 'unwinding assertion.*FAILURE')"
	echo "$v   (unwind-assert-fail: $u)"
}

echo "=================================================================="
echo " pgcl_tlb_flush.c — immediate flush_tlb_range coverage (zap/reclaim)"
echo "=================================================================="
run "BUG=0 faithful  (end=addr+nr*MMUPAGE)  EXPECT SUCCESS" pgcl_tlb_flush.c -DBUG=0
run "BUG=1 one-sub-PTE-keyed range          EXPECT FAILED" pgcl_tlb_flush.c -DBUG=1
run "BUG=2 PAGE-rounded, cluster straddles   EXPECT FAILED" pgcl_tlb_flush.c -DBUG=2
run "BUG=3 deferred gather half-range        EXPECT FAILED" pgcl_tlb_flush.c -DBUG=3
echo
echo "=================================================================="
echo " pgcl_tlb_reclaim_batch.c — x86 DEFERRED reclaim (#143's path)"
echo "=================================================================="
run "ARCH_FULL=1 x86 full flush              EXPECT SUCCESS" pgcl_tlb_reclaim_batch.c -DARCH_FULL=1
run "ARCH_FULL=0 range-batch, faithful range EXPECT SUCCESS" pgcl_tlb_reclaim_batch.c -DARCH_FULL=0
run "ARCH_FULL=0 range-batch, WRONG range    EXPECT FAILED" pgcl_tlb_reclaim_batch.c -DARCH_FULL=0 -DWRONG_RANGE=1
run "ARCH_FULL=1 x86 full flush, WRONG range EXPECT SUCCESS" pgcl_tlb_reclaim_batch.c -DARCH_FULL=1 -DWRONG_RANGE=1
echo
echo "Interpretation: BUG=0 SUCCESS = the FAITHFUL kernel flush range covers the"
echo "whole MMUPAGE cluster at every sub-page offset (PAGE-aligned AND straddling)."
echo "x86's deferred reclaim does a FULL flush, so it is gap-free by construction."
echo "=> no faithful flush-coverage gap leaves a stale TLB entry (matches the"
echo "   toolkit's QEMU TLBSCAN, which did NOT confirm stale-TLB as #143's cause)."
