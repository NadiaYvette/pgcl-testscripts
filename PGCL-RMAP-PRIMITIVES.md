# PGCL rmap primitives: the kernel-page rmap-event contract

Companion to `PGCL-MAPCOUNT-CONTRACT.md`. That doc decides *what a mapping is
counted in* (large folios: kernel-page units = "Contract A"; order-0: per-PTE).
This doc records *how the rmap primitives must be driven* to honour that contract
when a kernel page's `PAGE_MMUCOUNT` sub-PTEs are **not contiguous** — the case
that produced the intermittent residual after the first cut of Contract A landed.

## 1. The unit split, restated as an API rule

Under PGCL one kernel page (`PAGE_SIZE`) is mapped by up to `PAGE_MMUCOUNT`
hardware PTEs (`MMUPAGE_SIZE`). Every rmap-touching site therefore has to drive
**two** counters with **different units**:

| quantity            | unit              | primitive(s)                              |
|---------------------|-------------------|-------------------------------------------|
| refcount            | per **MMUPAGE PTE** | `folio_ref_add/sub`, `folio_put_refs`     |
| RSS (`MM_ANONPAGES`)| per **MMUPAGE PTE** | `rss[] += / -= nr`                        |
| mapcount (large)    | per **kernel page** | `folio_add/remove_rmap_pte`, `…dup…`      |
| mapcount (order-0)  | per **MMUPAGE PTE** | `folio_add/remove_rmap_pte` (looped)      |

So the API "splits analogously" to the user's question: the **refcount/RSS half**
of each primitive consumes `nr = pvmw.nr_mmupages` / `pgcl_pte_batch` count (the
hardware-PTE count of the yield), while the **mapcount half** fires **once per
kernel page**. They are the same call site but two different counts.

## 2. Why "once per yield" was not "once per kernel page"

The first implementation fired one rmap event per *walker yield* / per
*`pgcl_pte_batch` run*, assuming a kernel page is always presented in a single
run. That holds for the common cases (fresh fault, full `munmap`/`exit_mmap`,
full migrate) but **fails for a gapped cluster** — a kernel page some of whose
sub-PTEs are absent (left by partial COW, `MADV_DONTNEED`, sub-page `mprotect`):

- `page_vma_mapped_walk` batches only *contiguous* same-kernel-PFN PTEs, so a
  gapped kernel page is yielded in **several** runs (one per present fragment).
- `pgcl_pte_batch` (fork/zap) likewise stops at the first gap.

Firing the mapcount event per run then charges/uncharges a kernel page **once per
fragment** instead of once. The errors do **not** always self-cancel:

- **zap** of a gapped page: N runs → N removes → `_mapcount` underflows.
- **migration** of a gapped page: `try_to_migrate_one` over-removes the **src**
  folio while `remove_migration_pte` over-adds the **dst** folio. Different
  folios → no cancellation → dst is freed with a stale `_large_mapcount`
  (`bad_page` "nonzero large_mapcount"); the src underflow surfaces later as a
  negative `_mapcount` caught at the next zap.
- **fork** of a gapped page: N runs → N dup events → child `_large_mapcount`
  over-counted.

This was the laptop "corrupt-free page" class reproduced as the aarch64 PGCL=4
`cow` residual (order-2/3 mTHP, GUP-pin-driven migration churn).

## 3. The contract: one rmap event per kernel page, by edge detection

Each rmap-mutating site computes the kernel page's PTE window and fires the
mapcount event on exactly **one** edge, then keeps the refcount/RSS arithmetic
per-MMUPAGE as before:

```c
unsigned int sub  = (addr >> MMUPAGE_SHIFT) & (PAGE_MMUCOUNT - 1);
pte_t      *base  = ptep - sub;          /* first sub-PTE of this kernel page */
```

- **Remove side (last-present edge).** After this yield clears/converts its
  sub-PTEs, scan `base[0..PAGE_MMUCOUNT)`. Fire `folio_remove_rmap_pte` iff
  **none remain present** — i.e. this yield cleared the kernel page's *last*
  mapped fragment.
- **Add side (first-fragment edge).** Before this yield installs its sub-PTEs,
  scan the window. Fire the add iff **no sub-PTE is already present** — i.e. this
  is the *first* fragment of the kernel page being (re)mapped in this walk.

Both reduce to the trivial "one slot, always fires" at `PAGE_MMUCOUNT == 1`
(PGCL=0), so the whole construct is inert at the Newton limit — every block is
under `#if PAGE_MMUSHIFT`.

`order-0` folios never enter these branches (the scans are
`if (folio_test_large(folio))`-gated); they keep the per-PTE
`for (i < nr_pages) folio_{add,remove}_rmap_pte()` loop.

## 4. The five sites

| site | file | edge | event |
|------|------|------|-------|
| zap PTEs | `mm/memory.c` `zap_present_ptes` | last-present | `folio_remove_rmap_pte` |
| reclaim unmap | `mm/rmap.c` `try_to_unmap_one` | last-present | `folio_remove_rmap_pte` |
| migrate unmap (src) | `mm/rmap.c` `try_to_migrate_one` | last-present | `folio_remove_rmap_pte` |
| migrate remap (dst) | `mm/migrate.c` `remove_migration_pte` | first-fragment | `folio_add_{anon,file}_rmap_pte` |
| fork copy | `mm/memory.c` `copy_present_ptes` | first-fragment | `folio_try_dup_anon_rmap_ptes(.., 1, ..)` |

COW (`wp_page_copy`) and PMD map/zap are already kernel-page-unit (the faulting
page is the single event; the new COW folio is order-0; PMD uses
`_entire_mapcount`) and are unchanged.

## 5. The fork subtlety (the part that bit earlier attempts)

`folio_try_dup_anon_rmap_ptes` is **fused**: it makes the GUP-vs-fork pin /
`PageAnonExclusive` decision *and* counts. So fork cannot simply "skip the count"
on later fragments — the pin decision must stay consistent across the whole
kernel page. Two earlier attempts failed here:

1. **dup + undo** (`folio_sub_large_mapcount` on later fragments) — corrupted the
   per-MM id accounting; `folio_sub_large_mapcount` is **not** a clean inverse.
2. **count-on-first via "any present sub-PTE before me"** alone — wrong for a
   **pinned** page: the first fragment hits `EAGAIN` and *copies* (COW broken,
   page stays `AnonExclusive`); a later fragment would then wrongly *share*
   without breaking COW (the exact CVE the flag exists to prevent).

The correct rule keys off `PageAnonExclusive` to disambiguate:

- **first fragment** (no present sub-PTE before it): call the fused dup once. It
  decides pin/exclusive and counts the one mapping. On `EAGAIN`, fall through to
  the per-PTE copy path.
- **later fragment, page now `!PageAnonExclusive`**: an earlier fragment already
  dup-shared this kernel page → copy these sub-PTEs and take per-PTE refs, but do
  **not** count again. Sharing a non-exclusive page is always race-free, so no
  pin re-check is needed.
- **later fragment, page still `PageAnonExclusive`**: the first fragment must have
  hit `EAGAIN` and copied → fall through to the per-PTE copy path too (copy, no
  share, no stale source-folio count).

No new rmap primitive is required: "dup without count" for an already-shared,
already-non-exclusive page is *nothing* on the rmap side — only the PTE copy and
the per-MMUPAGE `folio_ref_add` remain, which already live outside the dup.

## 6. Invariants any future rmap site must keep

1. mapcount moves by **exactly 1 per kernel page per VMA-transition**; refcount
   and RSS move per MMUPAGE PTE.
2. Detect the kernel-page edge from the **PTE table window**, not from yield
   order — fragments may be non-adjacent and (for migrate) split across folios.
3. Remove fires on the **last** present fragment; add/dup fires on the **first**.
4. Everything stays under `#if PAGE_MMUSHIFT` and collapses to mainline at
   PGCL=0 (Newton limit is a hard regression gate).
5. order-0 folios keep per-PTE counting — never route them through the
   edge-detection branch.
6. **A single-sub-PTE fragment (nr == 1) of a large folio MUST still take the
   edge-detection path.** The batch helpers (`pgcl_pte_batch`) split a gapped
   kernel page into runs; a run can be a lone PTE. The fork/zap fast paths gate
   their PGCL block on `if (nr > 1)`, so a `[batch][single]` or `[single][batch]`
   split sent the single fragment to the generic per-PTE path, which fires an
   **unconditional** rmap event (dup / remove) and double-counts the kernel page.
   Gate large anon folios in regardless of `nr`: outer `max_nr > 1 ||
   folio_test_large(folio)`, inner `nr > 1 || folio_test_large(folio)`. This was
   the entire residual after the first edge-detection cut: ordering picked the
   symptom — `[batch][single]` → fork double-add ("nonzero large_mapcount" at
   free); `[single][batch]` → zap double-remove (negative `_mapcount`,
   "remove-on-unmapped"). Confirmed by an mm_id/`_large_mapcount` ledger: an
   order-3 folio took **9** fork dups for its 8 kernel pages.
7. **Edge-detect by the PHYSICAL sub-index, not the virtual address.** A large
   folio may be mapped MMUPAGE- (not kernel-page-) aligned — `mremap` /
   `relocate_vma_down` preserve the old `vm_pgoff`, so the PTE-encoded sub-index
   (`psub`) differs from the virtual one (`vsub = (addr >> MMUPAGE_SHIFT) &
   (PAGE_MMUCOUNT-1)`). A `vsub`-anchored window (`ptep - vsub`) then straddles
   two physical kernel pages, and the per-window scan both over-counts one page
   and under-counts its neighbour. Anchor the scan at the physical sub-0 slot
   (`ptep - psub`, where `psub = (pte_val / __phys_to_pte_val(MMUPAGE_SIZE)) &
   (PAGE_MMUCOUNT-1)`) and only count sub-PTEs whose `pte_pfn` equals this kernel
   page's — a neighbouring folio's PTE inside the window must never affect the
   decision. `pgcl_pte_batch` already groups by physical sub-index; the edge
   scans must match. This was the ~8% tail that survived invariant 6's fix
   (confirmed: cow maps the THP at `vsub=12`, `psub=0`).
8. **A kernel page can straddle the PTE-table (PMD) boundary** when misaligned.
   `pgcl_pte_batch` (capped by `max_nr` at the table edge) then splits the page
   across two `copy_present_ptes` / `zap_present_ptes` calls in *different* pte
   tables, and the previous table is already unmapped (`pte_offset_map_lock`), so
   the psub scan `ptep - psub` would read foreign memory. Detect the straddle
   from the slot index `idx = (addr >> MMUPAGE_SHIFT) & (PTRS_PER_PTE - 1)`:
   - **fork**: if `psub > idx` the page's sub-0 is in the prior (already-dup'd)
     table → this run is a continuation → `first_frag = false`.
   - **zap**: if `idx - psub + PAGE_MMUCOUNT > PTRS_PER_PTE` the page extends into
     the *next* table → that table's run owns the last-present remove → skip here;
     and bound the window scan to `[0, PTRS_PER_PTE)` (skip out-of-table slots).
   This was the final ~12% tail that survived invariant 7 (confirmed: FORKDUP
   showed one physical page dup'd twice as `(vsub=12 nr=4 psub=0)` +
   `(vsub=0 nr=12 psub=4)` across the boundary).

## 7. Verification

aarch64 PGCL=4, un-silenced (DEBUG_VM + DEBUG_VM_PGFLAGS + PAGE_OWNER), `cow`
selftest is the trigger (long-term GUP pins force migration of gapped mTHPs).
Each fix below was confirmed by the kernel's own `bad_page` checks **and** a
direct `_large_mapcount`/mm-id ledger (no folio exceeds its 2-process ceiling:
order-2 ≤ 8, order-3 ≤ 16).

- Baseline (pre-fix): ~40% of boots produced 41–83 `bad_page` markers
  ("nonzero large_mapcount" + a negative-`_mapcount` `remove-on-unmapped` WARN).
- Migration edge fix: `remove-on-unmapped` → 0 for the migration src/dst case.
- + fork first-frag + single-fragment gate: ~40% → ~8% (gapped/aligned solved).
- + psub (misalignment) fix: within-table over-dup gone (lmc=17→16 on order-3).
- + PMD-boundary straddle guard (invariant 8): **0 markers across 26 boots
  (16 SMP=1 + 10 SMP=4)**; cow PASS, full LTP, clean shutdown every run.
- The bug is a logic bug (reproduces at SMP=1), not a race.
- Newton x86_64/aarch64 PGCL=0 and PGCL=4 order-0: every block is `#if
  PAGE_MMUSHIFT` and collapses to mainline at shift 0; re-confirmed by boot.
