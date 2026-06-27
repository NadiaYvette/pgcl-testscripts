/*
 * pgcl_tlb_reclaim_batch.c — CBMC model of the x86 DEFERRED RECLAIM TLB path,
 * the path actually taken by #143's reclaim (try_to_unmap with TTU_BATCH_FLUSH).
 *
 * This is the most direct TLB surface for #143: kswapd/reclaim unmaps a cluster
 * under the PTL but DEFERS the TLB flush (set_tlb_ubc_flush_pending), then issues
 * the flush later in try_to_unmap_flush -> arch_tlbbatch_flush.
 *
 * THE LOAD-BEARING KERNEL FACT (arch/x86, read-only):
 *   - mm/rmap.c try_to_unmap_one (L2326-2327): if should_defer_flush(), call
 *       set_tlb_ubc_flush_pending(mm, pteval, address, end_addr)
 *     with end_addr = address + nr_mmupages*MMUPAGE_SIZE (the cleared span).
 *   - x86 arch_tlbbatch_add_pending (arch/x86/include/asm/tlbflush.h L371-378)
 *       IGNORES start/end ENTIRELY — it only inc_mm_tlb_gen + ORs mm_cpumask.
 *       There is NO per-address range recorded for the batch.
 *   - x86 arch_tlbbatch_flush (arch/x86/mm/tlb.c L1708-1737) issues a FULL flush:
 *       get_flush_tlb_info(NULL, 0, TLB_FLUSH_ALL, 0, ...) -> every CPU in the
 *       mask does flush_tlb_func with end==TLB_FLUSH_ALL -> flush_tlb_local()
 *       (the "Full flush" branch, tlb.c L1256-1262) i.e. invalidate EVERYTHING.
 *   - ORDER: reclaim's folio is freed only AFTER the batch flush
 *       (shrink_folio_list -> try_to_unmap_flush() before __remove_mapping /
 *       free), and __remove_mapping freezes refcount so a raced fault fails safe.
 *
 * CONSEQUENCE: on x86 the deferred reclaim path has NO range-coverage gap by
 * construction — the deferred flush is a FULL TLB flush, so it invalidates every
 * sub-PTE vaddr of every cluster regardless of how the (ignored) range was
 * computed.  A stale-TLB explanation for #143 on x86 is therefore impossible
 * via this path: even a deliberately-wrong range cannot leave a stale entry,
 * because the range is discarded and the whole TLB is flushed.
 *
 * KNOB ARCH_FULL:
 *   1 = x86 reality: deferred batch flush is a FULL flush (range ignored).
 *   0 = a HYPOTHETICAL arch whose batch flush honoured the recorded range
 *       (to show that IF an arch range-batched AND mis-recorded, it could leave a
 *        stale entry — i.e. the x86 fullness is what saves it, not the range calc).
 *
 * Single CPU (-smp1), explicit schedule (see pgcl_tlb_flush.c for the idiom).
 */

#define PAGE_MMUSHIFT   2
#define PAGE_MMUCOUNT   (1u << PAGE_MMUSHIFT)
#define MMUPAGE_SIZE    1u
#define PAGE_SIZE       (PAGE_MMUCOUNT * MMUPAGE_SIZE)

#ifndef ARCH_FULL
#define ARCH_FULL 1
#endif
/* WRONG_RANGE=1 records a deliberately-wrong one-sub-PTE batch range, to show
 * that a range-honouring arch (ARCH_FULL=0) WOULD then leave a stale entry, while
 * x86's full flush (ARCH_FULL=1) ignores the range and stays safe. */
#ifndef WRONG_RANGE
#define WRONG_RANGE 0
#endif
#ifndef NSTEPS
#define NSTEPS 12
#endif

#define OLD_PFN 7u

unsigned nondet_uint(void);

unsigned SUB_OFF;
#define VBASE  (1024u + SUB_OFF * MMUPAGE_SIZE)
#define VEND   (VBASE + PAGE_MMUCOUNT * MMUPAGE_SIZE)

int      pte_present[PAGE_MMUCOUNT];
unsigned pte_pfn_[PAGE_MMUCOUNT];
int      refcount, frame_freed, frame_reused;
int      tlb_valid[PAGE_MMUCOUNT];
unsigned tlb_pfn[PAGE_MMUCOUNT];

/* deferred reclaim batch: x86 records only "a flush is pending" + (ignored) range */
int           batch_pending;
unsigned long batch_start, batch_end;     /* recorded but IGNORED by x86 */

static inline unsigned vidx(unsigned long v){ return (unsigned)((v - VBASE)/MMUPAGE_SIZE); }

/* a FULL TLB flush: invalidate every entry (TLB_FLUSH_ALL -> flush_tlb_local) */
static void flush_all(void)
{
	unsigned k;
	for (k = 0; k < PAGE_MMUCOUNT; k++) tlb_valid[k] = 0;
}

/* a RANGE flush honoring [start,end): the hypothetical range-batch arch */
static void flush_range(unsigned long start, unsigned long end)
{
	unsigned long a;
	for (a = start; a < end; a += MMUPAGE_SIZE)
		if (a >= VBASE && a < VEND) tlb_valid[vidx(a)] = 0;
}

/* USER: one atomic access to a nondet cluster sub-PTE (walk+fill+use). */
static void user_step(void)
{
	unsigned i = nondet_uint();
	__CPROVER_assume(i < PAGE_MMUCOUNT);
	if (!tlb_valid[i] && pte_present[i]) { tlb_valid[i] = 1; tlb_pfn[i] = pte_pfn_[i]; }
	if (tlb_valid[i]) {
		unsigned hit = tlb_pfn[i];
		if (frame_freed)
			__CPROVER_assert(hit != OLD_PFN, "stale TLB: reclaim freed pfn read");
		if (frame_reused)
			__CPROVER_assert(hit != OLD_PFN, "stale TLB: reclaim OLD pfn of reused frame");
	}
}

/* KSW reclaim, as separate atomic steps (deferred window between clear and flush):
 *   0: try_to_unmap_one — clear PTEs under PTL, enqueue DEFERRED batch (no flush)
 *   1: try_to_unmap_flush — arch_tlbbatch_flush (x86: FULL flush)
 *   2: __remove_mapping/free — frame freed (refcount frozen; AFTER the flush)
 *   3: reuse */
unsigned ksw_pc;

static void ksw_step(void)
{
	if (ksw_pc == 0) {
		unsigned nr = PAGE_MMUCOUNT, k;
		unsigned long addr = VBASE;
		for (k = 0; k < nr; k++) { pte_present[k] = 0; refcount--; }
		/* set_tlb_ubc_flush_pending records the (on x86: ignored) range */
		batch_start = addr;
#if WRONG_RANGE
		batch_end = addr + 1 * MMUPAGE_SIZE;  /* deliberately wrong (one sub-PTE) */
#else
		batch_end = addr + nr * MMUPAGE_SIZE; /* faithful cleared span */
#endif
		batch_pending = 1;
		ksw_pc = 1;
	} else if (ksw_pc == 1) {
		/* try_to_unmap_flush -> arch_tlbbatch_flush */
		if (batch_pending) {
#if ARCH_FULL
			flush_all();              /* x86: FULL flush; range ignored */
#else
			flush_range(batch_start, batch_end);  /* hypothetical range-batch arch */
#endif
			batch_pending = 0;
		}
		ksw_pc = 2;
	} else if (ksw_pc == 2) {
		/* free happens AFTER the flush (try_to_unmap_flush precedes free in
		 * shrink_folio_list); __remove_mapping froze the refcount safely. */
		if (refcount == 0) frame_freed = 1;
		ksw_pc = 3;
	} else if (ksw_pc == 3) {
		if (frame_freed) frame_reused = 1;
		ksw_pc = 4;
	}
}

int main(void)
{
	unsigned s;
	SUB_OFF = nondet_uint();
	__CPROVER_assume(SUB_OFF < PAGE_MMUCOUNT);

	refcount = PAGE_MMUCOUNT;
	frame_freed = 0; frame_reused = 0; batch_pending = 0; ksw_pc = 0;
	for (s = 0; s < PAGE_MMUCOUNT; s++) {
		pte_present[s] = 1; pte_pfn_[s] = OLD_PFN; tlb_valid[s] = 0; tlb_pfn[s] = 0;
	}

	for (s = 0; s < NSTEPS; s++) {
		_Bool pick_ksw = nondet_uint() & 1;
		if (pick_ksw) { if (ksw_pc < 4) ksw_step(); else user_step(); }
		else          user_step();
	}
	return 0;
}
