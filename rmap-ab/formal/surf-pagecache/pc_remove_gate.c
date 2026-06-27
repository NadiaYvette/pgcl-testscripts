/*
 * pc_remove_gate.c  —  CBMC model of the PAGE-CACHE REF LIFECYCLE for a FILE
 * folio under PGCL, surface = "can the page-cache (xarray) ref be dropped, and
 * the folio freed, while a sub-PTE still maps the cluster?"
 *
 *   cbmc pc_remove_gate.c -DSCENARIO=n --unwind 16 --unwinding-assertions
 *
 * This is the page-cache twin of pgcl_orphan_faithful.c (which owns the rmap
 * teardown contract).  Here the focus is the TWO droppers of the page-cache ref:
 *   R  = reclaim   __remove_mapping  (mm/vmscan.c:686)
 *   T  = truncate  truncate_cleanup_folio + delete_from_page_cache_batch /
 *                  __filemap_remove_folio (mm/truncate.c:154,405; mm/filemap.c:222)
 * versus a faulting task F (filemap_map_pages / finish_fault) that installs
 * sub-PTEs + mapping refs while holding a lookup ref and the FOLIO LOCK.
 *
 * ==========================================================================
 * FAITHFUL FACTS (read-only from /home/nyc/src/linux; cited inline)
 *
 * PAGE-CACHE REF.  For a FILE folio the xarray holds exactly ONE ref for the
 *   whole folio (page_cache_delete drops it once; __remove_mapping's expected
 *   refcount = 1 + folio_nr_pages, i.e. 1 pagecache ref + folio_nr_pages
 *   mapping-or-other refs, all in PAGE/cluster units).  vmscan.c:728.
 * folio_mapped() == folio_mapcount() >= 1  (include/linux/mm.h:1951) — MAPCOUNT,
 *   blind to a present PTE whose rmap is gone (the orphan).
 *
 * RECLAIM gate (vmscan.c shrink_folio_list + __remove_mapping):
 *   if (folio_mapped()) try_to_unmap(folio);
 *   if (folio_mapped()) keep;                 // re-check, MAPCOUNT
 *   else __remove_mapping:
 *       expected = 1 + folio_nr_pages(folio); // CLUSTER units
 *       if (!folio_ref_freeze(folio, expected)) cannot_free;   // frees iff ==
 *       __filemap_remove_folio(folio); xa_unlock; ... folio_put implied via freeze.
 *   The freeze atomically requires actual==expected, so a STRAY mapping ref
 *   (refcount too high) makes freeze FAIL -> cannot_free.  A stray PTE whose
 *   *rmap is gone* contributes NO ref and NO mapcount -> invisible to BOTH gates.
 *
 * TRUNCATE (truncate_inode_pages_range mm/truncate.c:366):
 *   batch path: find_lock_entries() returns only folios FULLY within [start,end]
 *     in PAGE units and LOCKED (filemap.c:2179-2186 omit-before-start /
 *     omit-beyond-end); then truncate_cleanup_folio()->unmap_mapping_folio()
 *     [zaps ALL sub-PTEs of the folio via i_mmap, MMUPAGE-converted in
 *     unmap_mapping_range_tree memory.c:4838]; then delete_from_page_cache_batch
 *     -> page_cache_delete_batch drops the page-cache ref under i_pages lock,
 *     with filemap_unaccount_folio's VM_BUG_ON_FOLIO(folio_mapped()) guard
 *     (filemap.c:155 — MAPCOUNT).
 *   partial edges: __filemap_get_folio(FGP_LOCK) + truncate_inode_partial_folio
 *     ZEROES+SPLITS, does NOT remove the folio (mm/truncate.c:217-294) unless the
 *     whole folio is covered (length==size -> truncate_inode_folio).
 *
 * FAULT install (filemap_map_pages / do_read_fault->finish_fault):
 *   next_uptodate_folio: folio_try_get (LOOKUP ref) + folio_trylock (LOCK)
 *     (filemap.c:3729,3738).  PTEs+rmap installed UNDER the folio LOCK; the
 *     lookup ref is absorbed into mapping refs by folio_ref_add (filemap.c:3886 /
 *     memory.c:6628).  Lock released only AFTER install (do_read_fault
 *     memory.c:6776; "Locked folios cannot get truncated" filemap.c:3952).
 *
 * SERIALIZATION.  truncate_cleanup_folio, __filemap_remove_folio (truncate +
 *   reclaim) and the fault install all hold the FOLIO LOCK over the
 *   xarray-removal / mapping-install critical section.  This is the modeled
 *   mutual-exclusion: at most one of {fault-install, truncate-remove,
 *   reclaim-remove} holds the lock at a time.
 *
 * INVARIANTS:
 *   NO_FREE_WHILE_MAPPED — when the page-cache ref drop makes refcount hit 0 and
 *     the folio frees, NO sub-PTE is present.
 *   NO_PC_DROP_WHILE_MAPPED — the page-cache ref is never dropped (xarray slot
 *     cleared) while folio_mapped() (mapcount>=1) OR (stronger) while any sub-PTE
 *     is present.  We check both the mapcount form (what the kernel guards) and
 *     the PTE form (the true safety property), so a divergence = an orphan that
 *     fooled the gate.
 * ==========================================================================
 */

#include <assert.h>

#define NMM   2          /* two mms share the file folio (e.g. two mappers) */
#define NSUB  4          /* = PAGE_MMUCOUNT in the model (real 16) */

#ifndef SCENARIO
#define SCENARIO 1
#endif
#ifndef NSTEPS
#define NSTEPS 20
#endif

/* ---- shared state ---- */
int pte_present[NMM][NSUB];   /* per-(mm,sub-PTE) hardware PTE present */
int rmap[NMM][NSUB];          /* per-(mm,sub-PTE) rmap counted */
int refcount;                 /* folio _refcount (cluster-unit aggregate) */
int xslot;                    /* 1 = folio present in xarray (holds 1 pc ref) */
int folio_lock;               /* 0 free, else 1+actor id holding it */
int freed;

static int folio_mapcount(void)
{
	int m, i, c = 0;
	for (m = 0; m < NMM; m++)
		for (i = 0; i < NSUB; i++)
			c += rmap[m][i];
	return c;
}
#define folio_mapped() (folio_mapcount() >= 1)

static int any_pte_present(void)
{
	int m, i;
	for (m = 0; m < NMM; m++)
		for (i = 0; i < NSUB; i++)
			if (pte_present[m][i])
				return 1;
	return 0;
}

static void free_instant_check(void)
{
	if (refcount == 0 && !freed) {
		freed = 1;
		assert(!any_pte_present());        /* NO_FREE_WHILE_MAPPED */
	}
}

/* The page-cache ref drop is the load-bearing event: the folio leaves the
 * xarray and its protecting ref is gone.  Assert nothing maps it (both forms). */
static void drop_pagecache_ref(void)
{
	/* kernel guard: filemap_unaccount_folio VM_BUG_ON_FOLIO(folio_mapped()) */
	assert(!folio_mapped());               /* mapcount form (what kernel checks) */
	/* true safety property: no stray PTE either (orphan detector) */
	assert(!any_pte_present());             /* PTE form (NO_PC_DROP_WHILE_MAPPED) */
	xslot = 0;
	refcount -= 1;                          /* drop the single page-cache ref */
	free_instant_check();
}

/* ===== Actor F: fault install into mm Fm (filemap_map_pages cluster) ===== */
/* steps: acquire lock (try_get already gave +NSUB? no: lookup gives ONE ref,
 * absorbed; we model the real ref math: lookup +1, then folio_ref_add(nr-1)
 * to reach nr mapping refs for the cluster).  Holds lock across install. */
int F_pc, Fm;
static int F_step(void)
{
	int i;
	switch (F_pc) {
	case 0: /* next_uptodate_folio: folio_try_get (LOOKUP ref) */
		if (!xslot) { F_pc = 9; return 0; }     /* gone: lookup fails -> bail */
		refcount += 1;                          /* folio_try_get */
		F_pc = 1; return 0;
	case 1: /* folio_trylock */
		if (folio_lock) {                       /* held by T or R: must wait */
			/* if the holder removed the folio we'll observe !xslot after;
			 * model the wait as staying in this state */
			return 0;
		}
		/* re-validate under the just-acquired path: folio still in cache? */
		if (!xslot) {                           /* truncated/reclaimed meanwhile */
			refcount -= 1;                  /* drop lookup ref */
			free_instant_check();
			F_pc = 9; return 0;
		}
		folio_lock = 1 + 2;                     /* F holds lock (id 2) */
		F_pc = 2; return 0;
	case 2: /* install: rmap THEN pte (set_pte_range order), absorb lookup ref */
		for (i = 0; i < NSUB; i++) rmap[Fm][i] = 1;     /* folio_add_*_rmap */
		for (i = 0; i < NSUB; i++) pte_present[Fm][i] = 1; /* set_ptes */
		refcount += (NSUB - 1);                 /* folio_ref_add(nr-1): now NSUB mapping refs */
		F_pc = 3; return 0;
	case 3: /* unlock (do_read_fault folio_unlock) */
		folio_lock = 0;
		F_pc = 9; return 0;
	default:
		return 1;
	}
}

/* ===== Actor R: reclaim __remove_mapping on the folio ===== */
/* needs the folio lock; gate folio_mapped(); freeze iff refcount==expected. */
int R_pc;
static int R_step(void)
{
	int expected;
	switch (R_pc) {
	case 0: /* shrink_folio_list: trylock the folio */
		if (folio_lock) return 0;               /* held by F/T: wait */
		if (!xslot) { R_pc = 9; return 0; }     /* already gone */
		folio_lock = 1 + 3;                     /* R holds lock (id 3) */
		R_pc = 1; return 0;
	case 1: /* if (folio_mapped()) try_to_unmap; here reclaim's own unmap of ALL mms */
		if (folio_mapped()) {
			int m, i, n = 0;
			for (m = 0; m < NMM; m++)
				for (i = 0; i < NSUB; i++)
					if (pte_present[m][i]) {
						pte_present[m][i] = 0;  /* try_to_unmap clears PTE */
						rmap[m][i] = 0;        /* and drops rmap */
						n++;
					}
			refcount -= n;                  /* drops n mapping refs */
			free_instant_check();
		}
		R_pc = 2; return 0;
	case 2: /* re-check folio_mapped() (MAPCOUNT gate) */
		if (folio_mapped()) { folio_lock = 0; R_pc = 9; return 0; } /* keep */
		R_pc = 3; return 0;
	case 3: /* __remove_mapping: folio_ref_freeze(1 + folio_nr_pages) */
		expected = 1 + NSUB;   /* 1 pagecache + NSUB (cluster-unit nr_pages) */
		/* freeze frees iff actual == expected; if a stray mapping ref remains
		 * refcount != expected and freeze fails -> cannot_free. */
		if (refcount == expected) {
			/* freeze succeeded: __filemap_remove_folio drops the pc ref and
			 * the folio is removed; refcount goes to expected-1==NSUB then the
			 * caller folio_put's the NSUB... model the pagecache drop + the
			 * implied final put to 0 here as the kernel does post-freeze. */
			drop_pagecache_ref();           /* asserts not mapped; xslot=0; -1 */
			refcount = 0;                   /* folio_put_refs after freeze */
			free_instant_check();
		}
		folio_lock = 0;
		R_pc = 9; return 0;
	default:
		return 1;
	}
}

/* ===== Actor T: truncate of the WHOLE folio (batch path) ===== */
/* find_lock_entries locks the folio (only if fully in range); cleanup unmaps
 * ALL sub-PTEs; delete_from_page_cache_batch drops the pc ref. */
int T_pc;
static int T_step(void)
{
	int m, i, n;
	switch (T_pc) {
	case 0: /* find_lock_entries: folio_trylock (skip if locked) */
		if (folio_lock) return 0;               /* locked by F/R: skipped this batch; wait */
		if (!xslot) { T_pc = 9; return 0; }     /* already removed */
		folio_lock = 1 + 4;                     /* T holds lock (id 4) */
		T_pc = 1; return 0;
	case 1: /* truncate_cleanup_folio -> unmap_mapping_folio: zap ALL sub-PTEs */
		n = 0;
		for (m = 0; m < NMM; m++)
			for (i = 0; i < NSUB; i++)
				if (pte_present[m][i]) {
					pte_present[m][i] = 0;
					rmap[m][i] = 0;
					n++;
				}
		refcount -= n;                          /* mapping refs dropped by the zap */
		free_instant_check();
		T_pc = 2; return 0;
	case 2: /* delete_from_page_cache_batch: drop the page-cache ref */
		drop_pagecache_ref();                   /* asserts not mapped */
		T_pc = 3; return 0;
	case 3: /* folio_unlock + folio_batch_release (final put of the batch ref) */
		folio_lock = 0;
		if (!freed && refcount > 0) { refcount = 0; free_instant_check(); }
		T_pc = 9; return 0;
	default:
		return 1;
	}
}

static int F_done(void){ return F_pc >= 9; }
static int R_done(void){ return R_pc >= 9; }
static int T_done(void){ return T_pc >= 9; }

/* after every scheduler step: structural orphan / pc-while-mapped checks */
static void post_step_checks(void)
{
	int m, i;
	/* If the xarray slot is gone but a PTE is still present and rmap-counted,
	 * that's a folio removed from the cache while mapped (the bug class). */
	for (m = 0; m < NMM; m++)
		for (i = 0; i < NSUB; i++)
			assert(!(!xslot && pte_present[m][i]));   /* PC-removed-while-mapped */
	if (freed)
		assert(!any_pte_present());
}

int main(void)
{
	int step, who;

	freed = 0; xslot = 1; folio_lock = 0;
	F_pc = R_pc = T_pc = 0; Fm = 0;

	/* steady state: cluster mapped by BOTH mms; refcount = 1 pc + NMM*NSUB maps */
	for (int i = 0; i < NSUB; i++) {
		pte_present[0][i] = 1; rmap[0][i] = 1;
		pte_present[1][i] = 1; rmap[1][i] = 1;
	}
	refcount = 1 + NMM * NSUB;

#if SCENARIO == 1
	/* S1: RECLAIM vs FAULT.  mm1 unmapped (a fault F will re-install it); mm0
	 * mapped.  Reclaim R races the fault.  refcount = 1 pc + NSUB (mm0 maps). */
	for (int i = 0; i < NSUB; i++) { pte_present[1][i] = 0; rmap[1][i] = 0; }
	refcount = 1 + NSUB;
	Fm = 1;
	#define LIVE_F 1
	#define LIVE_R 1
	#define LIVE_T 0
#elif SCENARIO == 2
	/* S2: TRUNCATE vs FAULT (race #2).  Same start state as S1: T removes the
	 * whole folio while F tries to (re)install mm1. */
	for (int i = 0; i < NSUB; i++) { pte_present[1][i] = 0; rmap[1][i] = 0; }
	refcount = 1 + NSUB;
	Fm = 1;
	#define LIVE_F 1
	#define LIVE_R 0
	#define LIVE_T 1
#elif SCENARIO == 3
	/* S3: TRUNCATE vs RECLAIM on the same fully-mapped folio (both droppers
	 * of the pc ref race; both must take the folio lock). */
	#define LIVE_F 0
	#define LIVE_R 1
	#define LIVE_T 1
#elif SCENARIO == 4
	/* S4: all three — fault re-install of mm1 racing BOTH reclaim and truncate.
	 * The fullest interleave of the page-cache-ref lifecycle. */
	for (int i = 0; i < NSUB; i++) { pte_present[1][i] = 0; rmap[1][i] = 0; }
	refcount = 1 + NSUB;
	Fm = 1;
	#define LIVE_F 1
	#define LIVE_R 1
	#define LIVE_T 1
#endif

	for (step = 0; step < NSTEPS; step++) {
		who = nondet_int();
		__CPROVER_assume(who >= 0 && who < 3);
		if (who == 0 && LIVE_F && !F_done()) F_step();
		else if (who == 1 && LIVE_R && !R_done()) R_step();
		else if (who == 2 && LIVE_T && !T_done()) T_step();
		else continue;
		post_step_checks();
	}

	/* only judge COMPLETE interleavings (NSTEPS sized so completion is always
	 * reachable; coverage asserted in run.sh). */
	__CPROVER_assume((!LIVE_F || F_done()) && (!LIVE_R || R_done()) &&
			 (!LIVE_T || T_done()));

	/* drain any remaining ref to a definite end (e.g. F installed, nobody freed) */
	if (!freed && refcount > 0 && !xslot) {
		refcount = 0;
		free_instant_check();
	}

	post_step_checks();
	assert(!(freed && any_pte_present()));
	return 0;
}
