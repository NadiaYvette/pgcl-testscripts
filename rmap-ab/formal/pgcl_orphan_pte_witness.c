/*
 * pgcl_orphan_pte_witness.c — minimal, READABLE corroboration that the
 * straddle PTL-drop scenario ALONE is SAFE (VERIFICATION SUCCESSFUL). A
 * stripped 3-actor version (PVMW straddle walk + deferred zap + observer) of
 * the full pgcl_orphan_pte.c. Kept because its single freed&&present-in-T1
 * assertion makes the negative result easy to read: the cluster cannot reach
 * refcount 0 while mm0's second-table PTEs are still present, since the only
 * put that can reach 0 (mm0's yield-2 folio_put_refs) is sequenced AFTER mm0
 * clears those very PTEs. The orphan needs a UNIT-MISMATCH (pgcl_orphan_pte_v3.c),
 * not merely the dropped PTL.
 *
 *   cbmc pgcl_orphan_pte_witness.c --unwind 6      (expect: VERIFICATION SUCCESSFUL)
 *
 * MECHANISM (the §4 leading hypothesis, faithful to mm/rmap.c +
 * mm/page_vma_mapped.c, /home/nyc/src/linux):
 *   A cluster (one struct page = NSUB hardware sub-PTEs) is mapped by TWO mms
 *   (fork parent + child sharing the page). The cluster STRADDLES a pte-table
 *   (PMD) boundary, so the PVMW reclaim/migrate walk over mm0 tears it down in
 *   TWO yields, releasing the page-table lock (PTL) at the boundary
 *   (page_vma_mapped.c next_pte: spin_unlock; PVMW_PGTABLE_CROSSED; goto
 *   restart). Each yield clears its PTEs + drops its rmap + drops its refs
 *   (folio_put_refs) UNDER THE PTL (rmap.c:2310-2543). Concurrently mm1 is
 *   torn down by a PTL-only zap whose folio_put is DEFERRED out of the PTL
 *   (memory.c __tlb_remove_folio_pages -> tlb_finish_mmu).
 *
 *   The headline orphan: mm0's FIRST yield + mm1's deferred put together drop
 *   the cluster's refcount to 0 (it FREES) DURING the PTL gap, while mm0's
 *   SECOND table still has PRESENT PTEs. Those PTEs are now uncounted (their
 *   rmap-bearing yield has not run) and point at a freed cluster = an ORPHAN
 *   PTE. refcount/mapcount stayed perfectly balanced throughout — the very
 *   reason every count-based fix (and the freeze-while-mapped tripwire)
 *   A/B-refuted on the live -smp8 reproducer.
 *
 * We assert exactly one structural fact, evaluated by a 3rd observer thread so
 * the violating instant is explicit in the schedule:
 *   FREE_WHILE_MAPPED: never (freed && some pte_present[mm0][i in table T1]).
 */

#include <assert.h>

#define NSUB 4
#define BND  2          /* sub-PTEs [0,BND) in table T0, [BND,NSUB) in table T1 */

int refcount;
int pte_present[NSUB];   /* mm0's page-table present bits for the cluster */
int rmap_cnt;           /* mm0's rmap contribution for the cluster (sub-PTEs counted) */
int freed;
int gap_open;           /* set while mm0's PVMW walk sits in the PTL gap (T0 done, T1 pending) */
int mm1_pte;            /* mm1 still has the cluster mapped (1) or zapped (0) */
int doneW, doneZ, doneO;

/* mm0's two per-pte-table PTLs (the lock dropped mid-cluster lives here) */
int ptlT0, ptlT1;

#define LOCK(L)   do { int g; do { __CPROVER_atomic_begin(); g=(L); if(!g)(L)=1; __CPROVER_atomic_end(); } while(g); } while(0)
#define UNLOCK(L) do { __CPROVER_atomic_begin(); (L)=0; __CPROVER_atomic_end(); } while(0)

static void put_refs(int n)
{
	int last;
	__CPROVER_atomic_begin();
	refcount -= n;
	last = (refcount == 0);
	__CPROVER_atomic_end();
	if (last)
		freed = 1;
}

int main(void)
{
	int i;

	/* steady state: cluster fully mapped by both mms; refs = mm0(NSUB)+mm1(NSUB) */
	refcount = 2 * NSUB;
	rmap_cnt = NSUB;
	for (i = 0; i < NSUB; i++)
		pte_present[i] = 1;
	freed = 0; gap_open = 0; mm1_pte = 1;
	doneW = doneZ = doneO = 0;
	ptlT0 = ptlT1 = 0;

	/*
	 * THREAD W — PVMW unmap/migrate walk over mm0 (try_to_unmap_one).
	 * Yield 1 (table T0), drop PTL at the boundary, Yield 2 (table T1).
	 */
	__CPROVER_ASYNC_1: {
		/* yield 1: T0 sub-PTEs [0,BND) — clear PTE, drop rmap, drop refs */
		LOCK(ptlT0);
		for (i = 0; i < BND; i++) {
			pte_present[i] = 0;   /* get_and_clear_ptes */
			rmap_cnt--;          /* folio_remove_rmap_subptes */
		}
		put_refs(BND);              /* folio_put_refs(nr) — may free at 0 */
		gap_open = 1;              /* PVMW next_pte: about to release PTL mid-cluster */
		UNLOCK(ptlT0);            /* spin_unlock at the pte-table boundary */

		/* <<<<<< PTL GAP: T1's sub-PTEs [BND,NSUB) are STILL PRESENT >>>>>> */

		/* yield 2: T1 sub-PTEs [BND,NSUB) */
		LOCK(ptlT1);
		gap_open = 0;
		for (i = BND; i < NSUB; i++) {
			pte_present[i] = 0;
			rmap_cnt--;
		}
		put_refs(NSUB - BND);
		UNLOCK(ptlT1);
		doneW = 1;
	}

	/*
	 * THREAD Z — PTL-only zap of mm1 (zap_present_ptes); the folio_put is
	 * DEFERRED out of the PTL (tlb batch). mm1's PTEs+rmap clear first
	 * (under mm1's own PTL, not modeled separately — independent of mm0),
	 * then the deferred put drops mm1's refs.
	 */
	__CPROVER_ASYNC_2: {
		mm1_pte = 0;               /* clear_full_ptes + folio_remove_rmap_ptes (mm1 PTL) */
		put_refs(NSUB);            /* DEFERRED folio_put (tlb_finish_mmu, no PTL) */
		doneZ = 1;
	}

	/*
	 * THREAD O — observer. At any interleaving point it samples the state
	 * and asserts: the cluster is never freed while mm0's T1 table still
	 * holds a present (now-uncounted) PTE. A counterexample IS the orphan.
	 */
	__CPROVER_ASYNC_3: {
		assert(!(freed && pte_present[BND]));
		assert(!(freed && pte_present[NSUB - 1]));
		/* and the stronger orphan form: present in T1 while the gap is open
		 * and the cluster already freed by the racing puts */
		assert(!(gap_open && freed && pte_present[BND]));
		doneO = 1;
	}

	__CPROVER_assume(doneW && doneZ && doneO);
	return 0;
}
