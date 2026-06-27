/*
 * pgcl_orphan_pte_v2.c — VARIANT (b): a concurrent FAULT re-adds a mapping
 * while the cluster is being torn down. Tests whether a fault that installs a
 * PTE can race the teardown's freeing put to leave an orphan.
 *
 *   cbmc pgcl_orphan_pte_v2.c --unwind 8 --unwinding-assertions
 *
 * Faithful fault ordering (do_swap_page, mm/memory.c:5650-5695,
 * /home/nyc/src/linux), all UNDER the faulting PTL:
 *     folio_ref_add(nr)              // 1. bump refcount FIRST
 *     folio_add_anon_rmap_ptes(nr)   // 2. bump rmap
 *     set_ptes(nr)                   // 3. install the PTEs LAST
 * The lookup that re-finds the folio is modeled by a try_get-style guard: a
 * fault may only proceed if it acquires a ref while the cluster is alive
 * (folio_try_get / the pagecache/swapcache existence ref). A fault that finds
 * the cluster already freed must NOT install (it would retry / fetch fresh).
 *
 * Base teardown = the straddle PVMW walk over mm0 (as in pgcl_orphan_pte.c).
 * The fault targets mm1 (the child re-touching a shared swapped page).
 *
 * QUESTION: with the guard, can a fault still produce an orphan? Without the
 * guard (a plain folio_get / no existence ref), does it?
 */

#include <assert.h>

#define NMM  2
#define NSUB 4
#define BND  2

int refcount;
int rmap_sub[NMM][NSUB];
int pte_present[NMM][NSUB];
int freed;
int doneW, doneF;

int ptl[NMM][2];
#define LOCK(L)   do { int g; do { __CPROVER_atomic_begin(); g=(L); if(!g)(L)=1; __CPROVER_atomic_end(); } while(g); } while(0)
#define UNLOCK(L) do { __CPROVER_atomic_begin(); (L)=0; __CPROVER_atomic_end(); } while(0)

#define ORPHAN(m,i)  ( pte_present[m][i] && (freed || rmap_sub[m][i] == 0) )
#define NO_PTE_PRESENT()                                            \
	( !pte_present[0][0] && !pte_present[0][1] &&               \
	  !pte_present[0][2] && !pte_present[0][3] &&               \
	  !pte_present[1][0] && !pte_present[1][1] &&               \
	  !pte_present[1][2] && !pte_present[1][3] )

/*
 * Build-time switch:
 *   GUARD=1 : fault uses increment-unless-zero against a stable existence ref
 *             (folio_try_get) — the kernel's real discipline.
 *   GUARD=0 : fault uses a plain ref bump (models a missing/incorrect lookup
 *             guard, the #140 lookup-vs-free family).
 */
#ifndef GUARD
#define GUARD 1
#endif

static void put_refs(int n)
{
	int last;
	__CPROVER_atomic_begin();
	refcount -= n;
	last = (refcount == 0);
	if (last) {
		freed = 1;
		assert(NO_PTE_PRESENT());     /* free-while-mapped instant */
	}
	__CPROVER_atomic_end();
}

/* increment-unless-zero; returns 1 if a live ref was acquired, else 0. */
static int try_get(void)
{
	int ok;
	__CPROVER_atomic_begin();
	if (refcount == 0) { ok = 0; }
	else { refcount++; ok = 1; }
	__CPROVER_atomic_end();
	return ok;
}

static void clear_group(int m, int lo, int hi)
{
	int i;
	__CPROVER_atomic_begin();
	for (i = lo; i < hi; i++) {
		pte_present[m][i] = 0;
		rmap_sub[m][i] = 0;
	}
	__CPROVER_atomic_end();
}

int main(void)
{
	int i, got;

	/*
	 * Start: mm0 fully maps the cluster; mm1 has ONE sub-PTE unmapped
	 * (sub 0) that a concurrent fault will (re)install. Plus a stable
	 * existence ref (pagecache/swapcache) = +1, dropped never in this model
	 * (the folio's backing store keeps it alive). refcount = existence(1) +
	 * mm0(NSUB) + mm1(NSUB-1 already mapped).
	 */
	freed = 0; doneW = doneF = 0;
	for (i = 0; i < NSUB; i++) {
		pte_present[0][i] = 1; rmap_sub[0][i] = 1;
		pte_present[1][i] = 1; rmap_sub[1][i] = 1;
	}
	pte_present[1][0] = 0; rmap_sub[1][0] = 0;     /* the to-be-faulted sub-PTE */
	refcount = 1 + NSUB + (NSUB - 1);
	ptl[0][0] = ptl[0][1] = 0;
	ptl[1][0] = ptl[1][1] = 0;

	/* THREAD W — straddle PVMW teardown of mm0 (frees its share). */
	__CPROVER_ASYNC_1: {
		LOCK(ptl[0][0]);
		clear_group(0, 0, BND);
		put_refs(BND);
		UNLOCK(ptl[0][0]);
		LOCK(ptl[0][1]);
		clear_group(0, BND, NSUB);
		put_refs(NSUB - BND);
		UNLOCK(ptl[0][1]);
		/* also tear down mm1's pre-existing maps so the cluster can reach 0 */
		LOCK(ptl[1][0]);
		__CPROVER_atomic_begin();
		for (i = 1; i < NSUB; i++) { pte_present[1][i] = 0; rmap_sub[1][i] = 0; }
		__CPROVER_atomic_end();
		put_refs(NSUB - 1);
		UNLOCK(ptl[1][0]);
		doneW = 1;
	}

	/*
	 * THREAD F — fault (re)installing sub-PTE 0 of mm1, under mm1's PTL.
	 * Faithful order: ref bump, rmap bump, PTE install. With GUARD the ref
	 * bump is try_get (fails if already freed -> no install).
	 */
	__CPROVER_ASYNC_2: {
		LOCK(ptl[1][0]);
#if GUARD
		got = try_get();                 /* folio_try_get */
#else
		__CPROVER_atomic_begin(); refcount++; got = 1; __CPROVER_atomic_end();
#endif
		if (got) {
			rmap_sub[1][0] = 1;      /* folio_add_anon_rmap_ptes */
			pte_present[1][0] = 1;   /* set_ptes — install LAST */
		}
		UNLOCK(ptl[1][0]);
		/* The fault's own mapping is then torn down too (munmap/exit), so
		 * the cluster can reach 0 and we test the final state cleanly. */
		if (got) {
			LOCK(ptl[1][0]);
			clear_group(1, 0, 1);
			put_refs(1);
			UNLOCK(ptl[1][0]);
		}
		doneF = 1;
	}

	__CPROVER_assume(doneW && doneF);
	/* drop the existence ref last (backing store releases the folio) */
	put_refs(1);

	assert(freed);
	assert(!ORPHAN(0,0)); assert(!ORPHAN(0,1));
	assert(!ORPHAN(0,2)); assert(!ORPHAN(0,3));
	assert(!ORPHAN(1,0)); assert(!ORPHAN(1,1));
	assert(!ORPHAN(1,2)); assert(!ORPHAN(1,3));
	return 0;
}
