# PGCL #143 — surface: TLB / flush coherence under PGCL (CBMC)

Date: 2026-06-27. A CBMC model of the **TLB flush-coverage** strand of #143,
faithful to the kernel's PGCL flush-range computation, checking whether a
cluster's freed+reused sub-PTE can keep a STALE TLB entry on the single CPU of
the `-smp1` reproducer. Read-only against `/home/nyc/src/linux`; no kernel file
modified, nothing built or run in the guest. Sibling of the refcount/orphan-PTE
work in `formal/FINDINGS.md` (another agent) — that strand explicitly defers TLB
to "Tlb.lean / Property-2 shootdown territory" (its §5 item 3); this fills that
gap on the flush-coverage question.

Artifacts in `formal/surf-tlb/`:
- `pgcl_tlb_flush.c`         — IMMEDIATE `flush_tlb_range` path (zap/munmap +
                              non-batched reclaim); range computation = the BUG knob.
- `pgcl_tlb_reclaim_batch.c` — the x86 DEFERRED reclaim path actually taken by
                              #143 (`TTU_BATCH_FLUSH`); ARCH_FULL / WRONG_RANGE knobs.
- `run.sh`                   — the full 8-case matrix.
- `cbmc_run.log`            — captured matrix output.

## 0. BOTTOM LINE
**A faithful flush-coverage gap does NOT exist on x86.** The model is exhaustive
(within bounds; all unwinding assertions pass) and proves:

1. The **faithful** kernel flush range (`end = address + nr_mmupages*MMUPAGE_SIZE`,
   the SAME `nr` that was cleared) **covers the whole MMUPAGE cluster at every
   sub-page offset** — PAGE-aligned *and* straddling a PAGE/PMD boundary — so no
   stale TLB entry survives the flush. `VERIFICATION SUCCESSFUL`.
2. The **deferred reclaim path** that #143 actually exercises (`TTU_BATCH_FLUSH`
   -> `arch_tlbbatch_flush`) does a **FULL** TLB flush on x86 (`TLB_FLUSH_ALL`),
   so it is gap-free *by construction*: it invalidates every sub-PTE vaddr of
   every cluster regardless of the (discarded) recorded range. `SUCCESSFUL` even
   when the recorded range is deliberately wrong.

So a **pure-TLB / stale-translation explanation for #143 is ruled out** on x86 —
consistent with the toolkit's QEMU `PGCL_TLBSCAN` probe, which "ruled out
TLB-flush coverage" from outside the guest (RMAP-DEBUG-TOOLKIT.md §F), and with
the live `PGCL_OVERFLUSH` discriminator (escalating every flush to full did not
fix it). The model has TEETH: the same harness FAILS for three deliberately
broken range computations, so the faithful PASS is meaningful, not vacuous.

The real #143 lives where the other agent's model puts it: a **structural orphan
PTE from a unit-mismatch** between the PTE-clear and the (rmap, refcount) drop —
*not* a TLB-flush-range bug. The two findings are complementary and mutually
reinforcing: the present-PTE is left behind by the teardown books, not by a
missed TLB invalidation.

## 1. The kernel flush-range computation (read faithfully)
All citations from `/home/nyc/src/linux` (v7.1-era PGCL tree, `PFN_PTE_SHIFT ==
MMUPAGE_SHIFT`, `flush_tlb_range` stride = `MMUPAGE_SHIFT`).

### 1a. Immediate path — `flush_tlb_range(vma, address, end_addr)`
- `mm/rmap.c` `try_to_migrate_one` **L2312-2329**:
  `nr_pages = pvmw.nr_mmupages; end_addr = address + nr_pages*MMUPAGE_SIZE;`
  `get_and_clear_ptes(mm, address, pvmw.pte, nr_pages);` then
  `should_defer_flush() ? set_tlb_ubc_flush_pending(mm,pteval,address,end_addr)`
  `                     : flush_tlb_range(vma, address, end_addr);`
- `mm/rmap.c` `try_to_unmap_one` **L2769-2794** — identical shape.
- `mm/rmap.c` writeback/`folio_referenced_one` **L1165-1201** — identical
  (`end_addr = address + nr_pages*MMUPAGE_SIZE`).
The clear-unit and the flush-unit are the **same `nr_pages`**.

`pvmw.nr_mmupages` = count of consecutive present same-PFN sub-PTEs from the
yield address, capped to `PAGE_MMUCOUNT - sub_off` and to the walk `end`
(`mm/page_vma_mapped.c` **L334-367**). A cluster STRADDLING a pte-table (PMD)
boundary makes the walker drop the PTL and re-yield past the edge (`next_pte`
**L371-388**, `PVMW_PGTABLE_CROSSED`), so a straddling cluster is delivered as
<=2 yields and **each yield clears and flushes its OWN `nr`**. The "whole-folio
done" early-out (`nr_pages == folio_nr_pages*PAGE_MMUCOUNT`, **L2545**) runs
AFTER the per-yield flush (**L2794**) — loop-termination optimisation, not a
flush-coverage decision.

### 1b. Zap / munmap — mmu_gather
- `mm/memory.c` `zap_present_folio_ptes` **L1860/L1865**: `clear_full_ptes(..,nr,..)`
  then `tlb_remove_tlb_entries(tlb, pte, nr, addr)`.
- `include/asm-generic/tlb.h` **L672-683**: `tlb_remove_tlb_entries` ->
  `tlb_flush_pte_range(tlb, address, MMUPAGE_SIZE * nr)`.
- `__tlb_adjust_range` **L400-406**: `start = min(start,addr); end = max(end,
  addr+range_size)` — the gather range only ever GROWS, MMUPAGE-granular over the
  same `nr` (worst case over-flushes the inter-cluster gap; harmless).

### 1c. The actual invalidation is MMUPAGE-granular, starts exactly at start
- `arch/x86/mm/tlb.c` `flush_tlb_func` **L1240-1253**: `addr = f->start;`
  `while (addr < f->end) { flush_tlb_one_user(addr); addr += 1UL<<f->stride_shift; }`
  stride = `MMUPAGE_SHIFT` (`flush_tlb_range` macro, `arch/x86/include/asm/tlbflush.h`
  **L331-335**). `native_flush_tlb_one_user` **L1602** = `invlpg(addr)`, one MMU
  page. No PAGE-rounding of `start`.
- `get_flush_tlb_info` **L1402** escalates to FULL only when
  `(end-start)>>stride_shift > tlb_single_page_flush_ceiling(33)` — over-covers,
  never under-covers.
- Generic (non-x86) default `tlb_flush` **L457-468** = `flush_tlb_range(&vma,
  tlb->start, tlb->end)` — same gathered MMUPAGE range -> conclusion not x86-only.

### 1d. The deferred RECLAIM batch (the #143 path) — x86 is a FULL flush
Reclaim sets `TTU_BATCH_FLUSH` (`should_defer_flush` true when other CPUs carry
the mm):
- `mm/rmap.c` `set_tlb_ubc_flush_pending` **L742-752** passes `(start,end)` to
  `arch_tlbbatch_add_pending`.
- x86 `arch_tlbbatch_add_pending` (`arch/x86/include/asm/tlbflush.h` **L371-378**)
  **IGNORES `start`/`end`** — only `inc_mm_tlb_gen` + OR `mm_cpumask`. NO per-
  address range recorded.
- x86 `arch_tlbbatch_flush` (`arch/x86/mm/tlb.c` **L1708-1737**) issues a FULL
  flush: `get_flush_tlb_info(NULL, 0, TLB_FLUSH_ALL, 0, ...)` -> `flush_tlb_func`
  "Full flush" branch (**L1256-1262**, `flush_tlb_local()`).
- ORDER: reclaim frees only AFTER `try_to_unmap_flush()` (`shrink_folio_list`),
  and `__remove_mapping` `folio_ref_freeze(1+nr_pages)` (`mm/vmscan.c` ~L729)
  fails safe if a fault bumped the refcount.

### 1e. mmu_gather free is ordered AFTER the flush
`mm/mmu_gather.c` `tlb_flush_mmu` **L422-425**: `tlb_flush_mmu_tlbonly()` (TLB
invalidate) **then** `tlb_flush_mmu_free()` -> `free_pages_and_swap_cache`. =>
a cluster's frame cannot be freed (hence reused) until after its TLB entries are
invalidated. This closes the deferred-flush window for the zap/munmap path: no
"freed-and-reused but not-yet-flushed" instant exists.

## 2. The model
Single CPU (`-smp1`, the documented reproducer condition — MEMORY/G: #143
reproduces at `-smp 1`, ~2/3 under icount; scheduling-sensitive interleaving, not
a cross-CPU race). State: `pte_present[]/pte_pfn_[]` (the cluster page table,
PAGE_MMUCOUNT sub-PTEs; model =4, real =16 — bounds §4); `tlb_valid[]/tlb_pfn[]`
(the one CPU's TLB, a (vaddr->pfn) set filled LAZILY on a USER access to a PRESENT
pte); `refcount/frame_freed/frame_reused` (the frame's owner/freed state);
`g_start/g_end` (the deferred mmu_gather range, faithful `__tlb_adjust_range`);
`SUB_OFF` (the cluster's sub-page offset within its PAGE, **nondet in
[0,PAGE_MMUCOUNT)** -> explores PAGE-aligned AND every straddle).

Two actors share the one CPU via an **explicit nondeterministic schedule**: at
each of NSTEPS steps CBMC picks USER or KSW; exactly one advances per step (=
`-smp1`); a context switch is the step boundary. The DEFERRED window is explicit
— KSW's clear+enqueue, flush, free and reuse are SEPARATE steps, so USER can be
scheduled between them (fault-vs-kswapd). A USER access is one ATOMIC step (a HW
walk+fill+use is uninterruptible w.r.t. kswapd on one CPU). The kernel ordering
flush->free (§1e) is modelled by freeing in the finish step AFTER `apply_flush`.

INVARIANT (the task's): a USER access executed once the frame is freed/reused
must never resolve a cluster sub-PTE vaddr to `OLD_PFN`. Equivalently: after
unmap + tlb_finish, NO TLB entry maps any cluster sub-PTE vaddr to the old pfn.

KNOBS, `pgcl_tlb_flush.c` (range under test): `BUG=0` FAITHFUL (`end =
addr+nr*MMUPAGE_SIZE`); `BUG=1` keyed to ONE sub-PTE; `BUG=2` PAGE-rounded to the
containing-PAGE window; `BUG=3` gather grows by only `nr/2`.
KNOBS, `pgcl_tlb_reclaim_batch.c`: `ARCH_FULL` (x86 full flush vs a hypothetical
range-honouring arch) x `WRONG_RANGE` (faithful vs a wrong recorded range).

## 3. RESULTS (run.sh; cbmc 6.8.0; --unwind 13 --unwinding-assertions; ALL
unwinding assertions PASS => exhaustive within bounds)

```
pgcl_tlb_flush.c  (immediate flush_tlb_range coverage)
  BUG=0 faithful   end=addr+nr*MMUPAGE       VERIFICATION SUCCESSFUL
  BUG=1 one-sub-PTE-keyed range              VERIFICATION FAILED
  BUG=2 PAGE-rounded, cluster straddles      VERIFICATION FAILED
  BUG=3 deferred gather half-range           VERIFICATION FAILED

pgcl_tlb_reclaim_batch.c  (x86 DEFERRED reclaim, #143's path)
  ARCH_FULL=1 x86 full flush                 VERIFICATION SUCCESSFUL
  ARCH_FULL=0 range-batch, faithful range    VERIFICATION SUCCESSFUL
  ARCH_FULL=0 range-batch, WRONG range       VERIFICATION FAILED
  ARCH_FULL=1 x86 full flush, WRONG range    VERIFICATION SUCCESSFUL
```

### Interpretation
- **BUG=0 SUCCESSFUL** = faithful range covers the full cluster at every sub-page
  offset (solver freely chose `SUB_OFF`, incl. straddles); with flush-before-free
  (§1e) no stale entry can be read post-free.
- **BUG=1 / BUG=3 FAILED** = a one-sub-PTE-keyed flush, or a gather covering only
  part of the cleared span, leaves the other sub-PTEs' entries live -> read
  OLD_PFN after reuse. (Teeth.)
- **BUG=2 FAILED** = the exact gap the task hypothesised. Counterexample
  `SUB_OFF=3` (cluster straddles 3 sub-pages into the next PAGE): the PAGE-rounded
  window `[page_base, page_base+PAGE_SIZE)` leaves the **far sub-PTE (idx 3,
  beyond the PAGE boundary)** unflushed — `tlb_valid[3]=1, tlb_pfn[3]=OLD_PFN`
  survives, read stale after reuse. **The real kernel never builds this range**
  (§1a-1c: MMUPAGE-granular over the per-yield `nr`, `start` never PAGE-rounded,
  straddle delivered as two correctly-flushed yields) — so this is the *witness
  that the model would catch a gap*, confirming BUG=0's pass is real.
- **ARCH_FULL=1+WRONG_RANGE SUCCESSFUL vs ARCH_FULL=0+WRONG_RANGE FAILED** = the
  decisive discriminator for the #143 reclaim path: x86's deferred reclaim flush
  is FULL and ignores the recorded range, so even a mis-recorded range cannot
  leave a stale entry. x86's immunity is structural (the full flush), not
  contingent on the range calc being right.

Stability: BUG=0 stays SUCCESSFUL at NSTEPS=16/unwind=17 and under `--mm tso`
(x86 weak memory) — not an artifact of shallow depth or SC.

## 4. Bounds & exhaustiveness — explicit
- 2 actors on 1 CPU; NSTEPS=12 (unwind 13). KSW needs 4 steps (unmap, flush,
  free, reuse); >=1 USER warm-up + >=1 post-reuse USER read fit; CBMC explores
  ALL 2^NSTEPS schedule vectors x all USER targets x all `SUB_OFF`. Every loop
  unwinds within the bound (all `unwinding assertion ... SUCCESS`) => **no
  reachable interleaving omitted within these bounds**.
- **NSUB = PAGE_MMUCOUNT = 4** (real 16). Flush-coverage is a per-sub-PTE SPATIAL
  property (is each cluster vaddr in the flushed range?) -> **scale-invariant in
  NSUB**: a missed sub-PTE at 4 is a missed sub-PTE at 16, and the faithful
  `end = addr+nr*MMUPAGE_SIZE` spans all NSUB by construction. Straddle exercised
  via `SUB_OFF in [0,NSUB)` incl. the maximal `SUB_OFF=NSUB-1`.
- **Single cluster, single mm.** Stale-TLB-use-after-free is a property of ONE
  cluster's vaddrs vs ONE CPU's TLB; a second mm/cluster adds independent vaddr
  ranges and cannot UN-flush another cluster's entry -> no reachable violation
  missed. (Cross-mm rmap/refcount = a different surface, the other agent's.)
- **CBMC gotchas handled (so the result is trustworthy):**
  (a) `__CPROVER_ASYNC_n:` makes only the FIRST following statement async (the
      rest run in main) -> an ASYNC-based draft was malformed; the final model
      uses an explicit step scheduler (faithful to `-smp1`, free of that trap).
  (b) **Uninitialised GLOBALS are zero-initialised, NOT nondet** -> bare `unsigned
      SUB_OFF;` pinned the model to `SUB_OFF==0` (no straddle) and silently passed
      BUG=2. Fixed by `SUB_OFF = nondet_uint()` in `main`. (Bare uninit LOCALS are
      nondet, which is why the scheduler/USER-target worked; now explicit for
      clarity.) Standalone probe files relying on `__CPROVER_assume` over a global
      were vacuous (infeasible path) and discarded; the committed models assert
      over OBSERVABLE state, and the BUG!=0 FAILs confirm non-vacuity.

## 5. Why a pure-TLB explanation is inconsistent with #143 (cross-check)
Three independent lines agree it is NOT stale-TLB:
1. **This model**: faithful range covers the cluster (immediate path); the #143
   reclaim path is a FULL flush (no range to get wrong). No reachable
   free-while-TLB-cached state.
2. **The QEMU TLBSCAN/OVERFLUSH probe** (RMAP-DEBUG-TOOLKIT.md §F): probed
   stale-TLB from OUTSIDE the guest (non-perturbing) and did NOT confirm it;
   `PGCL_OVERFLUSH` (every flush -> full) did not fix the crash.
3. **The structural evidence** (other agent's `formal/FINDINGS.md` Part II + the
   live A/B): #143 is an **orphan PTE** — a sub-PTE left PRESENT after its
   rmap+refcount were removed (unit-mismatch between PTE-clear and ref/rmap-drop).
   The leftover PTE is a *page-table* entry, not a cached translation; reachable
   directly by a HW walk (no TLB needed), and the freed cluster's refcount reached
   0 normally. A TLB flush — full or ranged — does nothing about a PRESENT
   page-table entry. So even a perfect TLB story cannot explain the
   `Bad page map ... pfn refcount:0 mapcount:-1` symptom.

The flush is **not the mechanism**; the present-PTE is created by the teardown
books, and the fix is the UNIT INVARIANT in `try_to_unmap_one`/
`try_to_migrate_one`/`remove_migration_pte` (other agent's §II.6), not a
flush-range change.

## 6. The (non-)fix this surface implies
There is **no flush-range fix to make** for #143: the PGCL flush range is already
MMUPAGE-granular and covers the cluster (§1, §3 BUG=0). The model does pin down
the invariant the kernel already satisfies and any future arch port MUST keep:

  **Every cluster TLB flush must span all cleared sub-PTE vaddrs in MMUPAGE
  units: `[address, address + nr_cleared*MMUPAGE_SIZE)` with the SAME `nr` used to
  clear — never keyed to one sub-PTE, never PAGE-rounded, and (for a
  table-straddling cluster) issued per-yield so each cleared span is flushed.**
On x86 the deferred reclaim path is additionally safe because it is a FULL flush.
A new arch that range-batches deferred reclaim flushes (instead of x86's full
flush) must honour `set_tlb_ubc_flush_pending`'s `[start,end)` faithfully —
`pgcl_tlb_reclaim_batch.c ARCH_FULL=0` is the model that gates such an arch (it
FAILS the moment the recorded range is wrong).

A cheap arch-port TRIPWIRE the model motivates (the *positive* analogue of the
QEMU TLBSCAN): after any cluster teardown's flush, assert no TLB entry for the
cluster's vaddrs survives — i.e. the flushed `[start,end)` covers
`[cluster_base, cluster_base + PAGE_MMUCOUNT*MMUPAGE_SIZE)` restricted to the
cleared sub-PTEs. (Vacuously true on x86 via the full flush; bites only on a
hypothetical range-batching arch.)
