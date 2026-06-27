/*
 * pgcl_orphan_pte.c — CBMC concurrency model of PGCL #143 as an ORPHAN PTE
 * (a present page-table entry left behind after its rmap + refcount were
 * removed), NOT as a refcount miscount.
 *
 * Build/check (cbmc on $PATH = /home/nyc/.kani/kani-0.67.0/bin/cbmc, 6.8.0):
 *   cbmc pgcl_orphan_pte.c --unwind 8 --unwinding-assertions
 *
 * Companion files:
 *   pgcl_orphan_pte_v2.c   variant (b): a fault re-adds a mapping concurrently.
 *   pgcl_orphan_pte_v3.c   variant (c): reclaim folio_ref_freeze races a fault.
 *   pgcl_cluster*.c        the older refcount-only models (kept for contrast).
 *
 * ==========================================================================
 * WHY A NEW MODEL  (see pgcl143-rmap-underflow-hunt.md, 2026-06-27 entries)
 *
 * The earlier models track ONLY the refcount and "proved" a folio_try_get fix.
 * But on the live -smp8 reproducer FOUR count-based fix hypotheses were
 * A/B-REFUTED (reclaim TTU_SYNC skip; producer installs at refcount 0;
 * mis-set PageAnonExclusive; migrate mapcount/refcount imbalance), and a
 * freeze-while-mapped tripwire came back a CLEAN NEGATIVE (__remove_mapping
 * never frees a folio with folio_mapped() true). They all refute for ONE
 * structural reason: #143 is an ORPHAN PTE — a sub-PTE that stays PRESENT in
 * some mm AFTER that mapping's rmap AND its refcount contribution were already
 * removed. The orphan is INVISIBLE to count invariants: the leftover PTE is
 * UNCOUNTED (its rmap is gone) and the freed cluster's refcount reached 0
 * NORMALLY (every static path balances — the hunt confirmed this repeatedly).
 * So the state must be THREE-WAY and EXPLICIT per (mm, sub-PTE).
 *
 * ==========================================================================
 * THE PGCL OBJECT + SCENARIO
 *
 * ONE struct page per CLUSTER = PAGE_MMUCOUNT hardware sub-PTEs (16 @pgcl4):
 * a single shared refcount, a per-sub-PTE rmap mapcount (MMUPAGE units = the
 * live contract), and PAGE_MMUCOUNT present-bits PER mapping mm. TWO mms (fork
 * parent + child sharing the page, as the sd-parse-elf children do), each with
 * its OWN page-table lock (PTL). NSUB=4 sub-PTEs in the model; the cluster
 * STRADDLES a pte-table (PMD) boundary: [0,BND) in table T0, [BND,NSUB) in T1.
 *
 * ==========================================================================
 * TEARDOWN PROTOCOLS  (faithful to /home/nyc/src/linux)
 *
 * THREAD W — PVMW walk over mm0 = try_to_unmap_one / try_to_migrate_one
 *   (mm/rmap.c:2164). The walker (mm/page_vma_mapped.c) yields one cluster's
 *   worth of consecutive same-PFN sub-PTEs per PTL section (pvmw.nr_mmupages),
 *   and per yield, UNDER THE PTL (rmap.c:2310-2543):
 *       get_and_clear_ptes(nr) ; folio_remove_rmap_subptes(nr) ; folio_put_refs(nr)
 *   When a cluster STRADDLES a pte-table boundary the walker splits it across
 *   TWO yields in TWO PTL sections, DROPPING the PTL at next_pte
 *   (page_vma_mapped.c:374-388: spin_unlock; PVMW_PGTABLE_CROSSED; goto restart).
 *
 * THREAD Z — PTL-only zap of mm1 = zap_present_ptes / zap_present_folio_ptes
 *   (mm/memory.c:1843). Per batch UNDER mm1's PTL: clear_full_ptes ;
 *   folio_remove_rmap_ptes ; then the folio_put is DEFERRED out of the PTL
 *   (__tlb_remove_folio_pages -> tlb_finish_mmu, lockless).
 *
 * Per yield/batch, clear-PTE + drop-rmap are both under that section's PTL, so
 * they commit ATOMICALLY w.r.t. any other actor (a present PTE never coexists
 * with its-own-rmap-gone WITHIN a yield) — modeled with __CPROVER_atomic.
 *
 * ==========================================================================
 * THE STRUCTURAL INVARIANTS  (what counts cannot see)
 *
 *   NO_FREE_WHILE_MAPPED: asserted at the EXACT instant the cluster is freed
 *     (inside put_refs, when refcount hits 0 — the moment the frame returns to
 *     the allocator). If ANY mm still has a present PTE then, that PTE is an
 *     ORPHAN and the next reuse corrupts (print_bad_pte). Checking at the free
 *     instant — rather than via an arbitrary observer thread — avoids flagging
 *     benign mid-teardown transients: only a free that races a still-present
 *     PTE is the bug.
 *   NO_ORPHAN (final state): after both teardowns, no present PTE may persist
 *     in a freed/rmap-stripped cluster:  pte_present[m][i] => !freed && rmap.
 * A counterexample with the books balanced IS #143.
 *
 * RESULT (this faithful straddle model): VERIFICATION SUCCESSFUL — the §4
 * PTL-drop-mid-cluster hypothesis does NOT, by itself, produce an orphan,
 * because in both try_to_unmap_one and zap_present_ptes the folio_put for a
 * yield/batch is sequenced AFTER that yield's PTEs are cleared, so the refcount
 * cannot reach 0 while any contributing actor still holds a present PTE. The
 * orphan needs a UNIT-MISMATCH between the PTE-clear and the ref/rmap-drop —
 * see pgcl_orphan_pte_v3.c, which exposes it. (v2: a concurrent fault re-add
 * is also insufficient, even without folio_try_get.)
 * ==========================================================================
 */

#include <assert.h>

#define NMM  2
#define NSUB 4
#define BND  2          /* [0,BND) in pte-table T0; [BND,NSUB) in pte-table T1 */

int refcount;
int rmap_sub[NMM][NSUB];     /* per-(mm,sub-PTE) rmap contribution still counted */
int pte_present[NMM][NSUB];  /* per-(mm,sub-PTE) page-table present bit */
int freed;
int doneW, doneZ;

/* per-mm, per-pte-table PTL (T0 guards [0,BND), T1 guards [BND,NSUB)) */
int ptl[NMM][2];
#define LOCK(L)   do { int g; do { __CPROVER_atomic_begin(); g=(L); if(!g)(L)=1; __CPROVER_atomic_end(); } while(g); } while(0)
#define UNLOCK(L) do { __CPROVER_atomic_begin(); (L)=0; __CPROVER_atomic_end(); } while(0)

/* ORPHAN(m,i): a present PTE whose backing is gone (freed, or rmap removed). */
#define ORPHAN(m,i)  ( pte_present[m][i] && (freed || rmap_sub[m][i] == 0) )

/*
 * NO_FREE_WHILE_MAPPED, asserted at the EXACT instant the cluster is freed.
 * This is the kernel-faithful check: when refcount hits 0 the frame is handed
 * back to the allocator; if ANY mm still has a present PTE pointing at it, that
 * PTE is now an ORPHAN and the next reuse corrupts (print_bad_pte). Checking
 * here (rather than via an arbitrary observer thread) avoids counting benign
 * mid-teardown transients as bugs: only a free that races a still-present PTE
 * matters.
 */
#define NO_PTE_PRESENT()                                            \
	( !pte_present[0][0] && !pte_present[0][1] &&               \
	  !pte_present[0][2] && !pte_present[0][3] &&               \
	  !pte_present[1][0] && !pte_present[1][1] &&               \
	  !pte_present[1][2] && !pte_present[1][3] )

static void put_refs(int n)
{
	int last;
	__CPROVER_atomic_begin();
	refcount -= n;
	last = (refcount == 0);
	if (last) {
		freed = 1;
		/* the freeing instant — must be fully unmapped */
		assert(NO_PTE_PRESENT());
	}
	__CPROVER_atomic_end();
}

/* Clear a contiguous sub-PTE range of mm m and drop its rmap — one PTL
 * section, so atomic w.r.t. other actors. */
static void clear_group(int m, int lo, int hi)
{
	int i;
	__CPROVER_atomic_begin();
	for (i = lo; i < hi; i++) {
		pte_present[m][i] = 0;   /* get_and_clear[_full]_ptes */
		rmap_sub[m][i] = 0;     /* folio_remove_rmap_{subptes,ptes} */
	}
	__CPROVER_atomic_end();
}

int main(void)
{
	int i;

	/* steady state: cluster fully mapped by both mms; refs = all sub-PTE refs */
	freed = 0; doneW = doneZ = 0;
	refcount = NMM * NSUB;
	for (i = 0; i < NSUB; i++) {
		pte_present[0][i] = 1; rmap_sub[0][i] = 1;
		pte_present[1][i] = 1; rmap_sub[1][i] = 1;
	}
	ptl[0][0] = ptl[0][1] = 0;
	ptl[1][0] = ptl[1][1] = 0;

	/* THREAD W — PVMW straddle walk over mm0: two yields, PTL dropped between. */
	__CPROVER_ASYNC_1: {
		LOCK(ptl[0][0]);              /* yield 1: pte-table T0 */
		clear_group(0, 0, BND);
		put_refs(BND);                /* folio_put_refs — may free at 0 */
		UNLOCK(ptl[0][0]);           /* next_pte: PTL released at table boundary */
		/* <<<<<<<<<<<< PTL GAP: T1 sub-PTEs of mm0 STILL PRESENT >>>>>>>>>>>> */
		LOCK(ptl[0][1]);              /* yield 2: pte-table T1 */
		clear_group(0, BND, NSUB);
		put_refs(NSUB - BND);
		UNLOCK(ptl[0][1]);
		doneW = 1;
	}

	/* THREAD Z — PTL-only zap of mm1 with the folio_put DEFERRED out of the PTL. */
	__CPROVER_ASYNC_2: {
		LOCK(ptl[1][0]); LOCK(ptl[1][1]);
		clear_group(1, 0, NSUB);     /* clear_full_ptes + folio_remove_rmap_ptes */
		UNLOCK(ptl[1][1]); UNLOCK(ptl[1][0]);
		put_refs(NSUB);              /* DEFERRED folio_put (tlb_finish_mmu, no PTL) */
		doneZ = 1;
	}

	__CPROVER_assume(doneW && doneZ);

	/*
	 * FINAL-STATE checks (after both teardowns complete):
	 *  - the cluster must be freed (both mappings gone => refcount 0), and
	 *  - no orphan may PERSIST. A persistent orphan is an unconditional leak;
	 *    the per-free assertion above already catches a free that races a
	 *    still-present PTE (the corruption window).
	 */
	assert(freed);
	assert(!ORPHAN(0,0)); assert(!ORPHAN(0,1));
	assert(!ORPHAN(0,2)); assert(!ORPHAN(0,3));
	assert(!ORPHAN(1,0)); assert(!ORPHAN(1,1));
	assert(!ORPHAN(1,2)); assert(!ORPHAN(1,3));
	return 0;
}
