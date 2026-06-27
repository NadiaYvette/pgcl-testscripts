/*
 * pc_truncate_units.c  —  CBMC model of the PGCL PAGE-vs-MMUPAGE UNIT arithmetic
 * in the TRUNCATE / page-cache range path (#143 race #3).
 *
 *   cbmc pc_truncate_units.c -DMODE=n --unwind 32 --unwinding-assertions
 *
 * QUESTION (race #3): does any page-cache/truncate range computation use cluster
 * (PAGE) index where it should use MMUPAGE, so a PARTIAL-cluster truncate removes
 * a folio from the xarray (drops its page-cache ref) while sub-PTEs OUTSIDE the
 * truncated sub-range remain mapped (freed-while-mapped)?
 *
 * Unlike pc_remove_gate.c (which models the lock/ref interleave), this model is
 * ARITHMETIC: a file of MMUPAGE-granular bytes, folios at PAGE/cluster indices,
 * sub-PTEs at MMUPAGE granularity, and the EXACT index formulas the kernel uses.
 * We sweep an arbitrary truncate byte-offset `newsize` and verify the
 * folio-removal decision is consistent with the sub-PTE-unmap decision.
 *
 * ==========================================================================
 * FAITHFUL FORMULAS (mm/truncate.c, mm/memory.c; cited).  Let:
 *   MMUC  = PAGE_MMUCOUNT (sub-PTEs per cluster/folio-of-order-0)
 *   newsize (bytes), truncate to [newsize, EOF) removed.
 *
 * truncate_inode_pages_range (truncate.c:387,396):
 *   start = (lstart + PAGE_SIZE - 1) >> PAGE_SHIFT      // PAGE units, round UP
 *   end   = (lend == -1) ? -1 : (lend + 1) >> PAGE_SHIFT// PAGE units
 *   With ftruncate: lstart = newsize, lend = -1 (to EOF).
 *   -> start_cluster = ceil(newsize / PAGE_SIZE)
 *   Batch path removes folios with index in [start_cluster, EOF_cluster]
 *   ENTIRELY within range (find_lock_entries omit-before-start / beyond-end,
 *   filemap.c:2179-2184).  The boundary folio at floor(newsize/PAGE_SIZE) (if
 *   newsize not cluster-aligned) is NOT in the batch; it is handled by
 *   truncate_inode_partial_folio (truncate.c:217) -> ZERO + SPLIT, NOT removed
 *   unless length==size (full-folio).  So a folio is REMOVED iff its whole
 *   cluster lies at/after start_cluster.
 *
 * truncate_pagecache (truncate.c:786):
 *   holebegin = round_up(newsize, PAGE_SIZE)            // PAGE units (cluster!)
 *   unmap_mapping_range(mapping, holebegin, 0, 1)       // unmaps [holebegin,EOF)
 *   -> in MMUPAGE units the unmapped sub-PTE range starts at
 *      holebegin/MMUPAGE_SIZE = round_up(newsize,PAGE_SIZE)/MMUPAGE_SIZE
 *      = ceil(newsize/PAGE_SIZE) * MMUC          (cluster-aligned MMUPAGE)
 *
 * unmap_mapping_folio / unmap_mapping_range_tree (memory.c:4876,4838):
 *   first = folio->index (PAGE), last = folio_next_index-1 (PAGE)
 *   mmu_first = first << PAGE_MMUSHIFT, mmu_last = ((last+1)<<PAGE_MMUSHIFT)-1
 *   => zaps the WHOLE folio's MMUPAGE span [index*MMUC, (index+1)*MMUC).
 *
 * The safety property links the two: a folio is removed from the cache ONLY by
 *   (a) the batch path (whole cluster >= start_cluster), whose cleanup
 *       unmap_mapping_folio zaps ALL MMUC sub-PTEs of that folio, OR
 *   (b) truncate_inode_partial_folio with length==size (whole folio), same zap.
 * So removal always co-occurs with a full-folio zap.  The DANGER would be a unit
 * bug making the REMOVAL range (PAGE) and the UNMAP range (MMUPAGE) disagree on
 * WHICH sub-PTEs / which folio — leaving a mapped sub-PTE on a removed folio.
 * ==========================================================================
 */

#include <assert.h>

#ifndef MMUC
#define MMUC 4          /* PAGE_MMUCOUNT (real up to 64; 4 keeps it small) */
#endif
#ifndef NCLUST
#define NCLUST 3        /* number of folios/clusters in the file */
#endif
#ifndef MODE
#define MODE 0
#endif

#define NSUB (NCLUST * MMUC)   /* total MMUPAGE sub-PTEs in the file */

/* per-sub-PTE present (one mm); per-cluster xarray slot present */
int pte_present[NSUB];
int xslot[NCLUST];

/* ---- faithful index helpers ---- */
static unsigned ceil_div(unsigned a, unsigned b){ return (a + b - 1) / b; }

/*
 * Apply a faithful ftruncate(newsize_mmupages) where newsize is given in
 * MMUPAGE units (so we can hit sub-cluster offsets).  PAGE_SIZE == MMUC mmupages.
 *
 *   start_cluster = ceil(newsize_mmu / MMUC)            (truncate.c:387)
 *   removed clusters: [start_cluster, NCLUST)            (batch, fully in range)
 *   partial boundary cluster b = floor(newsize_mmu / MMUC) when newsize_mmu not
 *     cluster-aligned: ZEROED+SPLIT, NOT removed.
 *   unmap range start (truncate_pagecache holebegin): round_up(newsize_mmu,MMUC)
 *     i.e. start_cluster*MMUC  -> all sub-PTEs >= that are unmapped.
 *   PLUS: removal of a cluster co-unmaps its whole MMUC span (unmap_mapping_folio).
 */
static void ftruncate_mmu(unsigned newsize_mmu)
{
	unsigned start_cluster = ceil_div(newsize_mmu, MMUC);
	unsigned hole_start_sub = start_cluster * MMUC;  /* round_up(newsize,PAGE) in MMUPAGE */
	unsigned c, i;

	/* (1) unmap_mapping_range(holebegin=round_up(newsize,PAGE_SIZE), 0): clears
	 *     every sub-PTE at or beyond the cluster-rounded hole start. */
	for (i = hole_start_sub; i < NSUB; i++)
		pte_present[i] = 0;

	/* (2) truncate_inode_pages: remove (drop pc ref) every WHOLE cluster in
	 *     [start_cluster, NCLUST).  Each removal's truncate_cleanup_folio ->
	 *     unmap_mapping_folio zaps that folio's WHOLE MMUC span. */
	for (c = start_cluster; c < NCLUST; c++) {
		for (i = c * MMUC; i < (c + 1) * MMUC; i++)
			pte_present[i] = 0;          /* unmap_mapping_folio: whole folio */
		xslot[c] = 0;                        /* page-cache ref dropped */
	}

	/* (3) the partial boundary cluster (if any) is ZEROED+SPLIT but NOT removed:
	 *     xslot[b] stays 1.  Its sub-PTEs in [newsize_mmu, hole_start_sub) were
	 *     already cleared by step (1); sub-PTEs in [b*MMUC, newsize_mmu) (the
	 *     surviving part of the file) remain mapped AND xslot[b]==1 — SAFE. */

#if MODE == 1
	/*
	 * INJECTED UNIT BUG (the #143-adjacent class): suppose the removal loop used
	 * the MMUPAGE-granular hole start as a *cluster* index by mistake — i.e. it
	 * removed clusters starting at floor(newsize_mmu/1) treating mmupages as
	 * clusters, OR the unmap used PAGE_SHIFT where the slot used MMUPAGE.  Model
	 * the canonical historical bug: removal range computed in PAGE units but the
	 * unmap range computed in MMUPAGE units WITHOUT the cluster rounding, so a
	 * cluster gets its slot dropped while a sub-PTE below the hole stays mapped.
	 * Concretely: drop the boundary cluster's slot too (remove it) but DON'T
	 * unmap its surviving sub-PTEs.
	 */
	if (newsize_mmu % MMUC != 0) {
		unsigned b = newsize_mmu / MMUC;     /* boundary cluster */
		xslot[b] = 0;                        /* BUG: removed while sub-PTEs < newsize remain */
		/* note: pte_present[b*MMUC .. newsize_mmu) still 1 */
	}
#endif
#if MODE == 2
	/*
	 * INJECTED UNIT BUG variant: unmap range uses MMUPAGE start without cluster
	 * round-up (holebegin = newsize itself, not round_up to PAGE), but removal
	 * still removes whole clusters >= ceil.  Then a removed cluster whose start
	 * is below... actually removal already unmaps via unmap_mapping_folio, so the
	 * exposure here is the OPPOSITE: model an under-unmap where removal does NOT
	 * co-unmap (simulating a should_zap_folio/single_folio filter that skipped a
	 * sub-PTE under a unit-wrong address range). */
	for (c = start_cluster; c < NCLUST; c++) {
		/* re-mark one sub-PTE as still present after removal: an unmap that
		 * missed a sub-PTE because the zap address range was cluster-rounded
		 * the wrong way. */
		pte_present[c * MMUC + (MMUC - 1)] = 1;   /* BUG: sub-PTE survives removal */
	}
#endif
}

/* INVARIANT: no cluster whose xslot is dropped may have any present sub-PTE. */
static void check(void)
{
	unsigned c, i;
	for (c = 0; c < NCLUST; c++)
		if (!xslot[c])
			for (i = c * MMUC; i < (c + 1) * MMUC; i++)
				assert(!pte_present[i]);   /* removed-while-mapped */
}

int main(void)
{
	unsigned newsize_mmu, i, c;

	/* start: whole file mapped, all clusters in cache */
	for (i = 0; i < NSUB; i++) pte_present[i] = 1;
	for (c = 0; c < NCLUST; c++) xslot[c] = 1;

	/* arbitrary truncate point in MMUPAGE units within (0, NSUB] */
	newsize_mmu = nondet_uint();
	__CPROVER_assume(newsize_mmu >= 1 && newsize_mmu <= NSUB);

	ftruncate_mmu(newsize_mmu);
	check();

	/* additionally: every surviving (xslot==1) cluster's sub-PTEs at/after
	 * newsize_mmu must have been unmapped (data-correctness: no stale mapping
	 * beyond EOF). This is a SIGBUS-correctness check, weaker than the safety
	 * one; report separately. */
#if CHECK_SIGBUS
	for (i = newsize_mmu; i < NSUB; i++)
		assert(!pte_present[i]);   /* no mapped sub-PTE beyond new EOF */
#endif
	return 0;
}
