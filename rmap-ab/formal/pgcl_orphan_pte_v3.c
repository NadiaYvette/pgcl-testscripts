/*
 * pgcl_orphan_pte_v3.c — VARIANT (c): UNIT-MISMATCH teardown (the historically
 * confirmed #143 / #140 bug class). Two teardown paths that DISAGREE on the
 * counting unit for the SAME cluster: one removes/clears in MMUPAGE units
 * (PAGE_MMUCOUNT sub-PTEs per cluster), the other in CLUSTER units (1 per
 * cluster). When PTE-clearing and ref/rmap-dropping use different units, the
 * refcount can reach 0 (cluster freed) while sub-PTEs are still PRESENT, or a
 * ref can be dropped without clearing its PTE — the ORPHAN.
 *
 *   cbmc pgcl_orphan_pte_v3.c --unwind 8 --no-unwinding-assertions
 *
 * This is the model that DIRECTLY captures the mechanism the hunt keeps
 * circling (pgcl143 memory, 2026-06-27): "a ref dropped WITHOUT clearing its
 * PTE — and NO deterministic path does this" + the #140 history of i_mmap /
 * rmap-walk queries computed in the WRONG unit. We model the hypothesis that
 * SOME path (a residual unconverted site, or a straddling-cluster walk that
 * yields the wrong nr) drops refs/rmap in cluster units while the PTEs are
 * MMUPAGE-granular.
 *
 * MISMATCH switch:
 *   MISMATCH=0 : both sides MMUPAGE-uniform (the intended live contract).
 *   MISMATCH=1 : the walk drops ONE ref+rmap per cluster (cluster unit) but
 *                clears all PAGE_MMUCOUNT PTEs (MMUPAGE unit) — models an
 *                under-counted remove (the symptom: refcount falls too slow vs
 *                PTEs cleared -> a LEFTOVER ref; mirror of #143's "+1 stuck").
 *   MISMATCH=2 : the walk drops PAGE_MMUCOUNT refs (MMUPAGE) but clears only
 *                ONE PTE (cluster unit) — models an over-counted ref drop
 *                relative to PTEs cleared -> refcount hits 0 while PTEs PRESENT
 *                = free-while-mapped orphan directly.
 */

#include <assert.h>

#define NMM  2
#define NSUB 4          /* = PAGE_MMUCOUNT in the model */

int refcount;
int rmap_mmupage[NMM];        /* per-mm rmap in MMUPAGE units (sum of sub-PTE maps) */
int pte_present[NMM][NSUB];   /* per-(mm,sub-PTE) present bits */
int freed;
int doneA, doneB;

int ptl[NMM];
#define LOCK(L)   do { int g; do { __CPROVER_atomic_begin(); g=(L); if(!g)(L)=1; __CPROVER_atomic_end(); } while(g); } while(0)
#define UNLOCK(L) do { __CPROVER_atomic_begin(); (L)=0; __CPROVER_atomic_end(); } while(0)

#ifndef MISMATCH
#define MISMATCH 0
#endif

#define ANY_PTE_PRESENT()                                           \
	( pte_present[0][0] || pte_present[0][1] ||                 \
	  pte_present[0][2] || pte_present[0][3] ||                 \
	  pte_present[1][0] || pte_present[1][1] ||                 \
	  pte_present[1][2] || pte_present[1][3] )

static void put_refs(int n)
{
	int last;
	__CPROVER_atomic_begin();
	refcount -= n;
	last = (refcount <= 0);        /* <=0: an over-drop also "frees" */
	if (last) {
		freed = 1;
		/* FREE-WHILE-MAPPED: at the freeing instant nothing may be present */
		assert(!ANY_PTE_PRESENT());
	}
	__CPROVER_atomic_end();
}

/* count present PTEs of mm m (the true MMUPAGE map count) */
static int count_present(int m)
{
	int i, c = 0;
	for (i = 0; i < NSUB; i++)
		c += pte_present[m][i];
	return c;
}

int main(void)
{
	int i, cleared;

	freed = 0; doneA = doneB = 0;
	refcount = NMM * NSUB;          /* MMUPAGE-unit refs: PAGE_MMUCOUNT per mm */
	for (i = 0; i < NSUB; i++) {
		pte_present[0][i] = 1;
		pte_present[1][i] = 1;
	}
	rmap_mmupage[0] = NSUB;
	rmap_mmupage[1] = NSUB;
	ptl[0] = ptl[1] = 0;

	/*
	 * THREAD A — teardown of mm0. Under mm0's PTL it clears PTEs and drops
	 * rmap; the ref drop is its own step (deferred put). The UNIT used for
	 * the ref/rmap drop vs the PTE clear is the variable under test.
	 */
	__CPROVER_ASYNC_1: {
		LOCK(ptl[0]);
		__CPROVER_atomic_begin();
#if MISMATCH == 2
		/* clear only ONE PTE (cluster-unit clear) ... */
		pte_present[0][0] = 0;
		cleared = 1;
#else
		/* clear ALL sub-PTEs (MMUPAGE-unit clear) */
		for (i = 0; i < NSUB; i++) pte_present[0][i] = 0;
		cleared = NSUB;
#endif
#if MISMATCH == 1
		/* drop ONE rmap per cluster (cluster-unit) — UNDER-remove */
		rmap_mmupage[0] -= 1;
#else
		rmap_mmupage[0] -= cleared;
#endif
		__CPROVER_atomic_end();
		UNLOCK(ptl[0]);

		/* deferred put — ref unit: */
#if MISMATCH == 1
		put_refs(1);             /* cluster-unit ref drop (too few) */
#elif MISMATCH == 2
		put_refs(NSUB);          /* MMUPAGE-unit ref drop but only 1 PTE cleared */
#else
		put_refs(cleared);       /* matched: drop exactly what we cleared */
#endif
		doneA = 1;
	}

	/* THREAD B — teardown of mm1, MMUPAGE-uniform (the correct side). */
	__CPROVER_ASYNC_2: {
		LOCK(ptl[1]);
		__CPROVER_atomic_begin();
		for (i = 0; i < NSUB; i++) pte_present[1][i] = 0;
		rmap_mmupage[1] -= NSUB;
		__CPROVER_atomic_end();
		UNLOCK(ptl[1]);
		put_refs(NSUB);
		doneB = 1;
	}

	__CPROVER_assume(doneA && doneB);

	/*
	 * FINAL-STATE structural invariants:
	 *  - the cluster is freed,
	 *  - no PTE persists in a freed cluster (orphan), and
	 *  - rmap matches the present-PTE count per mm (no rmap/PTE drift).
	 */
	assert(freed);
	assert(!(freed && ANY_PTE_PRESENT()));               /* NO_FREE_WHILE_MAPPED */
	assert(rmap_mmupage[0] == count_present(0));          /* rmap == present PTEs (mm0) */
	assert(rmap_mmupage[1] == count_present(1));          /* rmap == present PTEs (mm1) */
	return 0;
}
