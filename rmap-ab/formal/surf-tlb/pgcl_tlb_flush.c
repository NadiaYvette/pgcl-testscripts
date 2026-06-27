/*
 * pgcl_tlb_flush.c — CBMC model of TLB / flush-coherence under PGCL for bug #143.
 *
 * SURFACE: stale-TLB-after-unmap on a SINGLE CPU (-smp1), deferred-flush window.
 *
 * A PGCL cluster = PAGE_MMUCOUNT consecutive hardware sub-PTEs mapping
 * consecutive sub-pages of ONE cluster pfn.  Hazard checked:
 *
 *   a cluster's sub-PTEs are cleared and the page freed+reused, but a STALE TLB
 *   entry on the CPU still translates one of the cluster's sub-PTE virtual
 *   addresses to the OLD (freed/reused) pfn -> a userspace access reads/writes
 *   the wrong page (corruption / the PID1-segv-from-reused-cluster, no
 *   munmap->bad_pte needed).
 *
 * INVARIANT (the task's):
 *   after unmap-cluster + tlb_finish, NO TLB entry maps any cluster sub-PTE
 *   vaddr to the old pfn — especially once that pfn is freed/reused.
 *   Operationally: a USER access, executed AFTER the frame is freed/reused, must
 *   never resolve a cluster sub-PTE vaddr to OLD_PFN.
 *
 * MODELLING APPROACH — explicit -smp1 schedule (robust; no reliance on CBMC
 * __CPROVER_ASYNC label-scope quirks).  Two actors share one CPU:
 *   - USER : touches the cluster's sub-PTE vaddrs (fills the TLB lazily on a
 *            present PTE, then "uses" the cached translation).
 *   - KSW  : kswapd/reclaim — unmaps the cluster (clear PTEs + enqueue deferred
 *            flush), later runs tlb_finish (apply flush, THEN free), then reuse.
 * At each of NSTEPS scheduling points CBMC picks (nondet) which actor advances
 * by ONE atomic step.  Exactly one actor runs per step => -smp1.  A context
 * switch is the boundary between steps.  The DEFERRED window is explicit: KSW's
 * "clear+enqueue" and its "finish(flush+free)" are SEPARATE steps, so USER can
 * be scheduled in between (the laptop's scheduling-sensitive interleaving;
 * MEMORY/G: #143 reproduces at -smp1, ~2/3 under icount).
 *
 * FAITHFUL to /home/nyc/src/linux (read-only; nothing edited):
 *  - flush range computed from the SAME nr that was cleared, MMUPAGE-granular:
 *      try_to_migrate_one: end_addr = address + nr_pages*MMUPAGE_SIZE;
 *        get_and_clear_ptes(..,nr_pages); flush_tlb_range(vma,address,end_addr)
 *        (mm/rmap.c L2312-2329; nr_pages = pvmw.nr_mmupages, the per-yield count
 *        from page_vma_mapped_walk L334-367, capped to PAGE_MMUCOUNT-sub_off and
 *        to the walk end => the flush span == the cleared span, even on a partial
 *        straddle/gap yield).
 *      zap_present_folio_ptes: clear_full_ptes(..,nr) then
 *        tlb_remove_tlb_entries(tlb,pte,nr,addr) (mm/memory.c L1860/L1865) ->
 *        tlb_flush_pte_range(tlb,addr,MMUPAGE_SIZE*nr) (asm-generic/tlb.h L675).
 *  - mmu_gather range accumulation: __tlb_adjust_range start=min, end=max(end,
 *    addr+range_size) (asm-generic/tlb.h L404-405) — only ever GROWS the range.
 *  - per-CPU invalidation loop: for(a=start;a<end;a+=1<<stride_shift) invlpg(a),
 *    stride_shift=MMUPAGE_SHIFT for PTE flushes (arch/x86/mm/tlb.c L1250-1253,
 *    native_flush_tlb_one_user L1602 invlpg drops the single MMU page at a).
 *  - ORDER flush-then-free: tlb_flush_mmu() = tlb_flush_mmu_tlbonly() THEN
 *    tlb_flush_mmu_free()/free_pages_and_swap_cache (mm/mmu_gather.c L422-425).
 *    => the frame cannot be freed/reused until after the cluster TLB invalidate.
 *
 * KNOBS (BUG): the range computation under test.
 *   0 = FAITHFUL: end = addr + nr*MMUPAGE_SIZE; nr = #PTEs cleared.
 *   1 = keyed to ONE sub-PTE: flush only [addr, addr+MMUPAGE_SIZE) regardless
 *       of nr cleared (the "range computed from one sub-PTE's address" gap).
 *   2 = PAGE-rounded to the cluster's containing PAGE window: when the cluster
 *       straddles into the next PAGE the far sub-PTEs are left unflushed.
 *   3 = deferred gather grows by only nr/2 (partial-coverage gather bug).
 * BUG==0 is the kernel.  BUG!=0 are deliberately-broken ranges, present ONLY to
 * prove the assertion has teeth and to name the exact shape a real gap takes.
 */

#define PAGE_MMUSHIFT   2                 /* PAGE_MMUCOUNT = 4 in the model (real 16) */
#define PAGE_MMUCOUNT   (1u << PAGE_MMUSHIFT)
#define MMUPAGE_SIZE    1u                /* 1 vaddr unit == 1 MMU page (model scale) */
#define PAGE_SIZE       (PAGE_MMUCOUNT * MMUPAGE_SIZE)

#ifndef BUG
#define BUG 0
#endif
#ifndef NSTEPS
#define NSTEPS 12                         /* scheduling steps; >= enough for all orders */
#endif

#define OLD_PFN 7u
#define NEW_PFN 9u

/* cluster start sub-page offset within its containing PAGE (nondet in [0,PMC)).
 * SUB_OFF==0 => PAGE-aligned cluster; >0 => straddles into the next PAGE.
 * NB: a GLOBAL is zero-initialised by CBMC (NOT nondet) — it is assigned a
 * nondet value at the top of main() so the straddle is actually explored. */
unsigned nondet_uint(void);
unsigned SUB_OFF;
#define VBASE  (1024u + SUB_OFF * MMUPAGE_SIZE)   /* first sub-PTE vaddr of cluster */
#define VEND   (VBASE + PAGE_MMUCOUNT * MMUPAGE_SIZE)

/* ---- shared machine state -------------------------------------------- */
int      pte_present[PAGE_MMUCOUNT];      /* page table: per-sub-PTE present bit */
unsigned pte_pfn_[PAGE_MMUCOUNT];        /* pfn each sub-PTE maps */
int      refcount;                        /* cluster frame refcount; freed at 0 */
int      frame_freed;                     /* sticky: refcount hit 0 AND freed */
int      frame_reused;                    /* sticky: frame re-allocated */

/* single-CPU TLB: one (vaddr->pfn) slot per cluster sub-PTE (a vaddr has one xlat) */
int      tlb_valid[PAGE_MMUCOUNT];
unsigned tlb_pfn[PAGE_MMUCOUNT];

/* deferred mmu_gather range [g_start,g_end) (MMUPAGE units) */
unsigned long g_start, g_end;
int      g_active;

static inline unsigned vidx(unsigned long v) { return (unsigned)((v - VBASE) / MMUPAGE_SIZE); }

/* __tlb_adjust_range */
static void tlb_adjust_range(unsigned long addr, unsigned long range_size)
{
	if (!g_active) { g_start = addr; g_end = addr + range_size; g_active = 1; }
	else {
		if (addr < g_start) g_start = addr;
		if (addr + range_size > g_end) g_end = addr + range_size;
	}
}

/* the real per-CPU invalidation loop: invlpg every MMU page in [start,end) */
static void apply_flush(unsigned long start, unsigned long end)
{
	unsigned long a;
	for (a = start; a < end; a += MMUPAGE_SIZE)
		if (a >= VBASE && a < VEND)
			tlb_valid[vidx(a)] = 0;       /* invlpg(a): drop this vaddr's TLB entry */
}

/* ---- USER actor: one atomic CPU access to an ARBITRARY cluster sub-PTE -- */
/* The USER touches a NONDETERMINISTIC sub-PTE vaddr each step (it may touch any
 * cluster address, in any order, any number of times — CBMC explores all).
 * Each user step is ONE atomic CPU access (walk + lazy TLB fill + use), which is
 * the -smp1 uninterruptible-w.r.t.-kswapd granularity. */
static void user_step(void)
{
	unsigned i = nondet_uint();           /* nondeterministic target sub-PTE */
	__CPROVER_assume(i < PAGE_MMUCOUNT);

	/* lazy TLB fill: only a PRESENT pte can be walked to fill the TLB */
	if (!tlb_valid[i] && pte_present[i]) {
		tlb_valid[i] = 1;
		tlb_pfn[i]   = pte_pfn_[i];
	}
	/* use the cached translation, if any */
	if (tlb_valid[i]) {
		unsigned hit = tlb_pfn[i];
		/* INVARIANT: once the frame is freed/reused, NO live user translation
		 * may still resolve a cluster sub-PTE vaddr to the OLD pfn. */
		if (frame_freed)
			__CPROVER_assert(hit != OLD_PFN,
			    "stale TLB: user access hit FREED cluster pfn");
		if (frame_reused)
			__CPROVER_assert(hit != OLD_PFN,
			    "stale TLB: user access hit OLD pfn of a REUSED frame");
	}
}

/* ---- KSW actor: reclaim teardown as 3 sequential atomic steps ---------- */
/*   ksw_pc 0: unmap-cluster   (clear all sub-PTEs + enqueue deferred flush)
 *   ksw_pc 1: tlb_finish      (apply flush, THEN free the frame)
 *   ksw_pc 2: reuse_frame     (a fresh allocation takes the frame)
 * These are SEPARATE steps so USER can interleave in the deferred window. */
unsigned ksw_pc;

static void ksw_step(void)
{
	if (ksw_pc == 0) {                    /* unmap-cluster (one PTL section) */
		unsigned nr = PAGE_MMUCOUNT;     /* full-cluster yield: clear all */
		unsigned long addr = VBASE;
		unsigned k;
		for (k = 0; k < nr; k++) {
			pte_present[k] = 0;          /* clear_full_ptes / get_and_clear_ptes */
			refcount--;                  /* one ref per cleared sub-PTE (MMUPAGE) */
		}
#if BUG == 0
		tlb_adjust_range(addr, MMUPAGE_SIZE * nr);            /* faithful */
#elif BUG == 1
		tlb_adjust_range(addr, MMUPAGE_SIZE * 1);             /* one-sub-PTE keyed */
#elif BUG == 2
		{ unsigned long pb = (addr / PAGE_SIZE) * PAGE_SIZE;
		  tlb_adjust_range(pb, PAGE_SIZE); }                  /* PAGE-rounded window */
#elif BUG == 3
		tlb_adjust_range(addr, MMUPAGE_SIZE * (nr / 2));      /* half-range gather */
#endif
		ksw_pc = 1;
	} else if (ksw_pc == 1) {            /* tlb_finish_mmu: tlbonly THEN free */
		if (g_active) { apply_flush(g_start, g_end); g_active = 0; }
		if (refcount == 0) frame_freed = 1;
		ksw_pc = 2;
	} else if (ksw_pc == 2) {            /* the frame is reused by a new alloc */
		if (frame_freed) frame_reused = 1;
		ksw_pc = 3;                       /* done */
	}
}

/* ---- explicit -smp1 scheduler ---------------------------------------- */
int main(void)
{
	unsigned s;
	SUB_OFF = nondet_uint();                  /* GLOBAL: must be assigned nondet */
	__CPROVER_assume(SUB_OFF < PAGE_MMUCOUNT); /* explore PAGE-aligned AND straddle */

	/* initial: whole cluster mapped to OLD_PFN, refcounted, TLB cold */
	refcount = PAGE_MMUCOUNT;
	frame_freed = 0; frame_reused = 0;
	g_active = 0; ksw_pc = 0;
	for (s = 0; s < PAGE_MMUCOUNT; s++) {
		pte_present[s] = 1;
		pte_pfn_[s]    = OLD_PFN;
		tlb_valid[s]   = 0;
		tlb_pfn[s]     = 0;
	}

	/* run NSTEPS scheduling steps; at each, nondet-pick USER or KSW.  Exactly
	 * one actor advances per step (-smp1).  CBMC explores ALL choice vectors,
	 * i.e. every -smp1 interleaving of the two actors up to NSTEPS. */
	for (s = 0; s < NSTEPS; s++) {
		_Bool pick_ksw = nondet_uint() & 1;  /* nondeterministic scheduler decision */
		if (pick_ksw) {
			if (ksw_pc < 3) ksw_step();
			else            user_step(); /* ksw done: keep the user running */
		} else {
			user_step();
		}
	}
	return 0;
}
