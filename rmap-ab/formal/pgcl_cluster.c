/*
 * pgcl_cluster.c — a CBMC concurrency model of the PGCL #143 free-while-mapped race.
 *
 * Build/check:
 *   cbmc pgcl_cluster.c --unwind 2
 * (cbmc on $PATH = /home/nyc/.kani/kani-0.67.0/bin/cbmc, version 6.8.0)
 *
 * Concurrency is expressed with CBMC's native __CPROVER_ASYNC_n: labels rather
 * than pthread_create — the Kani-bundled CBMC's pthread_create builtin bails on
 * the start-routine function pointer ("pointer handling for concurrency is
 * unsound", no verdict). __CPROVER_ASYNC spawns each labelled block as a thread
 * and lets CBMC interleave at every statement, which is also a *more* faithful
 * model of the page-table-lock (PTL) gap: each line is a potential preemption
 * point, exactly the property the kernel loses when it drops/retakes the PTL and
 * defers the refcount put.
 *
 * --------------------------------------------------------------------------
 * THE BUG (abstracted; see pgcl143-rmap-underflow-hunt.md)
 *
 * PGCL clustering backs N = PAGE_MMUCOUNT hardware sub-PTEs with ONE refcounted
 * object (folio). Per cluster:
 *      refcount      : freed when it reaches 0.
 *      mapcount[i]   : per-sub-PTE rmap count (PGCL "Option A", per sub-PTE).
 *      pte[i]        : sub-PTE i present (a live hardware mapping).
 *
 *   fault/add(i):  pte[i]=1; mapcount[i]++; refcount++.     (all under one PTL)
 *   zap/remove(i): pte[i]=0; mapcount[i]--; refcount--;     (NON-atomic: the
 *                  if refcount==0 -> free                     PTE clear is under
 *                                                             PTL; the ref drop
 *                                                             / folio_put is
 *                                                             tlb-batch DEFERRED
 *                                                             to a later, lockless
 *                                                             critical section)
 *
 * INVARIANT (#143's corruption): never free (refcount==0) while any pte[i]==1.
 * Freeing while mapped -> frame reused -> dangling PTE -> page-cache corruption
 * / PID1 SIGSEGV. CBMC searches the interleavings for a violation.
 *
 * SCENARIO: two threads operate on the SAME shared cluster — the fork+reclaim
 * case the QEMU TLB-scan caught: a parent and a forked child each hold a live
 * mapping of the same shared file folio; each tears its own mapping down
 * independently, and the refcount/folio_put is deferred so the two teardowns
 * interleave. N=3 sub-PTEs, two threads, bounded ops, so the checker terminates.
 * --------------------------------------------------------------------------
 */

#include <assert.h>

#define N 3

/* ---- the shared cluster (one struct page / folio) ---------------------- */
int refcount;        /* atomic in the kernel; cluster freed at 0 */
int mapcount[N];     /* per-sub-PTE rmap count (Option A) */
int pte[N];          /* per-sub-PTE "present" bit (a live HW mapping) */
int freed;           /* sticky: set the instant refcount reaches 0 */

/* completion flags so the checker can wait for both threads */
int doneA, doneB;

/*
 * THE INVARIANT — freed (refcount==0) must imply no sub-PTE still present.
 * Written N-unrolled (no loop) so CBMC does not introduce loop-unwinding noise.
 * A counterexample to this IS the #143 free-while-mapped race.
 */
#define CHECK_NO_FREE_WHILE_MAPPED()                       \
	do {                                               \
		assert(!(freed && pte[0]));                \
		assert(!(freed && pte[1]));                \
		assert(!(freed && pte[2]));                \
	} while (0)

int main(void)
{
	/* the single shared sub-PTE both threads contend on (file folio, same pgoff) */
	int s = 0;

	/* pristine cluster: nothing mapped, not yet allocated/ref'd */
	refcount = 0; freed = 0; doneA = 0; doneB = 0;
	mapcount[0] = mapcount[1] = mapcount[2] = 0;
	pte[0] = pte[1] = pte[2] = 0;

	/*
	 * Thread A: fault in sub-PTE s, then zap it.
	 *
	 * fault/add is one PTL-covered critical section (rmap/ref before the PTE is
	 * observable = the safe order). zap is split: the PTE clear + mapcount drop
	 * happen under PTL; the ref drop / folio_put is DEFERRED (the tlb-batched
	 * put) — modeled as a later, separately-interleavable region.
	 */
	__CPROVER_ASYNC_1: {
		/* fault/add(s) */
		mapcount[s]++;
		refcount++;
		pte[s] = 1;
		CHECK_NO_FREE_WHILE_MAPPED();

		/* zap(s): under-PTL clear + rmap drop */
		pte[s] = 0;
		mapcount[s]--;

		/* deferred put (tlb_finish_mmu / folio_put), no PTL */
		refcount--;
		if (refcount == 0) freed = 1;
		CHECK_NO_FREE_WHILE_MAPPED();

		doneA = 1;
	}

	/* Thread B: same shared sub-PTE, same independent fault-then-zap. */
	__CPROVER_ASYNC_2: {
		mapcount[s]++;
		refcount++;
		pte[s] = 1;
		CHECK_NO_FREE_WHILE_MAPPED();

		pte[s] = 0;
		mapcount[s]--;

		refcount--;
		if (refcount == 0) freed = 1;
		CHECK_NO_FREE_WHILE_MAPPED();

		doneB = 1;
	}

	/* wait for both threads, then check the final state */
	__CPROVER_assume(doneA && doneB);
	CHECK_NO_FREE_WHILE_MAPPED();
	return 0;
}
