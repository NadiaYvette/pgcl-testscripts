# PGCL large-folio mapcount contract

Status: IMPLEMENTED + VERIFIED (worktree `linux-pgcl-mc`). The `cow`-selftest
large-folio mapcount residual is drilled to **zero**: 26/26 un-silenced aarch64
PGCL=4 boots (16 SMP=1 + 10 SMP=4) with 0 `bad_page` markers, after five layered
fixes (gapped-cluster edge, migration/reclaim edge, fork first-frag, single-PTE
fragment gate, physical-sub-index + PMD-boundary-straddle edge detection). The
rmap-event mechanics live in `PGCL-RMAP-PRIMITIVES.md` (invariants 1–8).
Resolves task #119 (aarch64 PGCL=4/6 large-folio freed-while-mapped; same class
as the laptop pgcl0 corrupt-free).

> Terminology note: the *existing tree* comments call per-MMUPAGE-PTE counting
> "Option A".  This document's "Contract A" means the OPPOSITE — kernel-page-unit
> counting.  To avoid the clash the new code says "Contract A (large folios)" /
> "order-0: per-PTE" explicitly and drops the bare "Option A" labels.

## 0. What the reproducer actually showed (confirmed before patching)

aarch64 PGCL=4, un-silenced (`cow` test): an **order-2 mTHP anon folio**
(`GFP_TRANSHUGE`, allocated in `vma_alloc_folio`) freed with a tail page's
`_mapcount` raw = 5 and the head's `_nr_pages_mapped` residual — `bad_page`,
"nonzero mapcount". It is **not** a PMD THP (PMD order on aarch64-64K is 13) and
**not** `__split_huge_pmd`; it is a PTE-mapped large (mTHP) folio. aarch64-only
because aarch64's large-anon-folio policy hands `cow` an order-2 folio where
x86_64 PGCL=4 stays order-0 — so only aarch64 exercises the large-folio
clustering zap/COW. x86_64/riscv64/ppc64/s390x are clean at 0/4/6; aarch64_0
(Newton) is clean.

### Root cause (mechanism)

The whole tree counts mapcount **per MMUPAGE PTE** (one rmap event per hardware
PTE), held consistent across fault/fork/COW/zap/PVMW by fixups. That works for
order-0 (one kernel page → no mis-distribution) and for the PVMW paths (which
loop `nr_pages` times correctly). It breaks for **large folios** because the
large-folio fast paths use `folio_pte_batch()`, whose returned count is
incoherent under PGCL: the loop counts MMUPAGE PTEs but `max_nr` is clamped to
*kernel-pages*-remaining (`folio_pfn + folio_nr_pages - pte_pfn`, internal.h
~390). The resulting `nr` is then fed to `folio_remove_rmap_ptes(folio, page,
nr)` / `folio_try_dup_anon_rmap_ptes(folio, page, nr)` which walk `page[0..nr-1]`
= `nr` *distinct kernel pages* (`__folio_add/remove_rmap` does `page++`). So the
N MMUPAGE PTEs of **one** kernel page get charged/uncharged across N **different**
kernel pages of the folio → residual per-page `_mapcount`, freed-while-mapped.

Per-MMUPAGE counting is also fundamentally incompatible with upstream's
large-folio machinery: it drives `_large_mapcount` to `nr_ptes` (=
`nr_pages*PAGE_MMUCOUNT`), tripping `__folio_large_mapcount_sanity_checks`
(`diff <= folio_large_nr_pages`) and the `folio_large_mapcount > folio_nr_pages`
WARN in `__wp_can_reuse_large_anon_folio`. Large folios therefore *must* count
in kernel-page units.

## 1. The problem

Under PGCL a kernel page (`PAGE_SIZE`) is mapped to userspace by up to
`PAGE_MMUCOUNT` hardware (`MMUPAGE_SIZE`) PTEs. The kernel's rmap/mapcount
machinery has to decide what a "mapping" is counted in. Today the tree is
**internally inconsistent about that unit**, and the inconsistency is the bug:

- Large-folio **PMD** map/zap use upstream accounting in **kernel-page units**
  (`_entire_mapcount`, `_large_mapcount += 1`, `_nr_pages_mapped` in page units).
- The **PMD→PTE split** fixup (`__split_huge_pmd_locked`,
  `mm/huge_memory.c` ~3204-3219) and the **order-0 fork/COW** paths count in
  **MMUPAGE-PTE units** (`atomic_add(PAGE_MMUCOUNT-1, &page->_mapcount)`,
  `folio_add_large_mapcount(HPAGE_PMD_MMUNR - HPAGE_PMD_NR)`).

A folio that crosses between the two regimes (PMD-mapped, then split, then
PTE-zapped; or mixed-size concurrent mappings across mms via fork/mremap) has
its `_mapcount` / `_nr_pages_mapped` driven to a residual or negative value, so
it is freed while still "mapped" → `bad_page`. Empirically: order-5 THP freed at
`exit_mmap` with per-page `_mapcount` residual and `_nr_pages_mapped` ≈
`-PAGE_MMUCOUNT`.

## 2. Two candidate contracts

**Contract A — mapcount counts kernel-page *mappings* (one per (kernel page,
VMA)).** The `PAGE_MMUCOUNT` MMUPAGE PTEs of a kernel page are a hardware detail
*below* the rmap layer; together they realise ONE mapping for accounting.

**Contract B — mapcount counts MMUPAGE *PTEs* (up to `PAGE_MMUCOUNT` per kernel
page per VMA).** (This was the original, mostly-unforeseen-subtleties intent, and
what the split fixup does locally.)

Both are internally consistent *if applied uniformly*. The tree mixes them.

## 3. Decision: Contract A

Rationale:

1. **It is the only one compatible with upstream's machinery unchanged.**
   `folio_mapcount() == _large_mapcount + 1`; the `__folio_large_mapcount_sanity_checks`
   cap is `diff <= folio_large_nr_pages` (kernel-page units); `_nr_pages_mapped`
   counts pages-mapped-at-least-once with the `ENTIRELY_MAPPED` sentinel. B blows
   the sanity cap (`HPAGE_PMD_MMUNR > HPAGE_PMD_NR`) and inflates `folio_mapcount`
   by `PAGE_MMUCOUNT`, which would require PGCL-patching the sanity check,
   `folio_mapcount`, and every consumer (reclaim/migration/`folio_mapped` heuristics).
2. **It matches the PGCL rmap convention already in the tree** — "exactly one
   rmap event per PVMW yield (per kernel page)" (try_to_unmap/migrate, the zap
   anon-batch, the fork batch already follow this for the walker side).
3. **It keeps mapcount where PGCL says it belongs** — at kernel-page granularity,
   consistent with "one `struct page` per kernel page." Counting MMUPAGE PTEs
   leaks the hardware page back up into kernel bookkeeping, which is precisely the
   impedance mismatch PGCL exists to avoid.
4. **It is identity at `PAGE_MMUSHIFT==0`** (`PAGE_MMUCOUNT==1` → one event per
   kernel page == upstream per-page).

### 3a. Scope: large folios only; order-0 keeps per-PTE counting

Contract A is applied to **large folios** (`folio_test_large`). Order-0 folios
have **no** `_large_mapcount`/`_nr_pages_mapped` (those are large-folio fields),
so per-MMUPAGE-PTE counting of a single order-0 kernel page trips nothing and is
left exactly as-is — this keeps the working order-0 paths (every non-aarch64 arch
in the sweep) **untouched, zero regression risk**. The shared paths that handle
both (PVMW unmap/migrate/remap, COW neighbour loop, fork batch) branch on
`folio_test_large`: large → one rmap event per kernel page; order-0 → the
existing per-PTE loop.

This is *not* a third regime: a folio never changes the unit it is counted in
during its life. The one boundary — a large folio **split to order-0**
(`__split_huge_page`) — is safe because split is a full teardown (`unmap_folio`
removes all rmap) + rebuild (`remap_page` re-adds it), and
`__split_folio_to_order` flips the folio non-large *before* `remap_page` runs, so
`remove_migration_pte` rebuilds the order-0 sub-folios with per-PTE counting
automatically. Nothing is "preserved" across the split.

> Implementation note (correcting the earlier "mostly deletion" sketch): the
> large-folio zap and fork can **not** keep using `folio_pte_batch()` (its PGCL
> count is incoherent — see §1). They are routed through the existing per-kernel-
> page `pgcl_pte_batch()` blocks (previously order-0-only), with the rmap call
> made once per kernel page for large folios. So it is *deletion of the
> Contract-B fixups* PLUS *routing large anon folios into the per-kernel-page
> path* PLUS *a `folio_test_large` branch in the four shared loops* — not pure
> deletion.

## 4. The contract

PRINCIPLE: **mapcount counts mappings at kernel-page granularity, exactly as
mainline counts them at base-page granularity.** A kernel page is "mapped by a
VMA" iff ≥1 of its `PAGE_MMUCOUNT` MMUPAGE PTEs in that VMA is present.

INVARIANTS:

1. `page->_mapcount` (per kernel page) = number of VMAs currently mapping that
   kernel page. Range −1 (unmapped) .. (#mappers−1). Identical to mainline at
   `PAGE_MMUSHIFT==0`.
2. `_large_mapcount`, `_nr_pages_mapped`, `_entire_mapcount`: mainline meanings,
   kernel-page units. The `diff <= nr_pages` sanity check holds unchanged.
3. `folio_mapcount()`: mainline meaning and value — no PGCL adjustment, no
   consumer changes.
4. **Exactly one rmap event per (kernel page, VMA) mapping transition**:
   `folio_add_*_rmap_*` when the kernel page's mapping in a VMA goes
   absent→present (first MMUPAGE PTE installed); `folio_remove_rmap_*` when it
   goes present→absent (last MMUPAGE PTE removed).

KEY SEPARATION — **refcount and mapcount are different units, on purpose:**

| counter   | unit                     | a kernel page mapped by N MMUPAGE PTEs in 1 VMA |
|-----------|--------------------------|--------------------------------------------------|
| refcount  | per MMUPAGE PTE (a ref)  | +N (each PTE pins the page)                       |
| mapcount  | per (kernel page, VMA)   | +1 (one mapping)                                 |

So `refcount >= mapcount` always holds (the invariant whose violation is the
crash). Today's bug is the split making *mapcount* also count PTEs while the
remove path disagrees.

## 5. Code changes (as implemented — worktree `linux-pgcl-mc`)

All large-folio paths gated by `folio_test_large`; all PGCL blocks `#if
PAGE_MMUSHIFT`; all no-ops at shift 0 (`PAGE_MMUCOUNT==1`, one PTE per page, the
`!(PAGE_MMUSHIFT && ...)` guards collapse to the original conditions).

**Map side — delete the Contract-B inflation (large folios only):**
- `mm/memory.c map_anon_folio_pte_nopf` — deleted the `if (nr_pages > 1) { for…
  atomic_add(PAGE_MMUCOUNT-1, &page->_mapcount); folio_add_large_mapcount(nr_ptes
  - nr_pages) }`. `folio_add_new_anon_rmap` already gives kernel-page-unit
  mapcount; `folio_ref_add(nr_ptes-1)` (per-PTE refs) stays.
- `mm/memory.c do_swap_page` — deleted the identical large-folio fixup.
- `mm/huge_memory.c __split_huge_pmd_locked` (both `!freeze` and `freeze`) —
  deleted both fixups; `folio_add_anon_rmap_ptes(.., HPAGE_PMD_NR, ..)` +
  `folio_ref_add(HPAGE_PMD_MMUNR-1)` already give the right units.
- `do_anonymous_page` order-0 inline block (`atomic_add(rss-1, &_mapcount)`) —
  **unchanged** (order-0 keeps per-PTE).

**Remove / copy side — branch on `folio_test_large`:**
- `mm/memory.c zap_present_ptes` — the upstream `folio_pte_batch` large-folio fast
  path is disabled for PGCL anon (`!(PAGE_MMUSHIFT && folio_test_anon)`), routing
  large anon folios into the per-kernel-page `pgcl_pte_batch` block; there the
  rmap drop is one `folio_remove_rmap_pte` for large folios, else the per-PTE
  loop. PTE clear / TLB / `rss -= nr` / `folio_ref_sub(nr-1)` + `__tlb_remove_
  page_size` are MMUPAGE-granular and shared (so refs stay per-PTE).
- `mm/memory.c copy_present_ptes` (fork) — same fast-path disable for PGCL anon;
  the per-kernel-page block takes large folios with **first-fragment edge
  detection** (scan the source window before this run; the fused
  `folio_try_dup_anon_rmap_ptes(.., 1, ..)` fires once per kernel page). Later
  fragments key off `PageAnonExclusive` to either share-without-count (page now
  non-exclusive) or fall through to per-PTE copy (still exclusive ⇒ first
  fragment hit `EAGAIN` and copied a pinned page). `atomic_add(nr-1, &_mapcount)`
  guarded `if (!folio_test_large)` (order-0); `folio_ref_add(nr)` per-PTE shared.
  See §6 / `PGCL-RMAP-PRIMITIVES.md` §5.
- `mm/memory.c wp_page_copy` (COW) — the faulting `folio_remove_rmap_pte(old)` is
  the single kernel-page event; the per-neighbour `folio_remove_rmap_pte(old)` is
  guarded `if (!folio_test_large(old_folio))`. `extra` still counts every
  neighbour for `folio_ref_sub(old, extra)` (per-PTE). `new_folio` is always
  order-0 (`folio_prealloc`) so its `atomic_add(extra, &_mapcount)` stays.
- `mm/rmap.c try_to_unmap_one`, `try_to_migrate_one` — large folios fire
  `folio_remove_rmap_pte(.. subpage ..)` once per kernel page via **last-present
  edge detection** (scan the window after this yield clears/migrates its PTEs;
  fire iff none remain present). order-0 keeps the `for (i<nr_pages)` loop.
  `folio_put_refs(folio, nr_pages)` (per-PTE) shared.
- `mm/migrate.c remove_migration_pte` — large-folio anon/file rmap-add fires once
  per kernel page via **first-fragment edge detection** (scan the window before
  `set_ptes`; fire iff no sub-PTE already restored), else `for (i<nr_pages)`. Also
  makes the split→order-0 boundary self-correct (folio is non-large by the time
  `remap_page` runs).

**Unchanged:** PMD map/zap (`folio_add_new_anon_rmap` PMD branch, `zap_huge_pmd`)
— already kernel-page-unit via `_entire_mapcount`. RSS (`MM_ANONPAGES`) and
`folio_ref_*` — MMUPAGE-granular by design (resident hardware pages / per-PTE
pins), independent of the mapcount unit.

## 6. Partial-mapping note — gapped clusters need an explicit edge scan

A kernel page with only *some* sub-PTEs present (a **gapped cluster**, left by
partial COW / `MADV_DONTNEED` / sub-cluster `mprotect`) is **not** presented to
the rmap sites in a single yield: `page_vma_mapped_walk` batches only
*contiguous* same-PFN PTEs and `pgcl_pte_batch` stops at the first gap, so a
gapped kernel page is handled in **several** runs (one per present fragment).

The first cut of this contract fired one rmap event per *run*, which over/under-
counts a gapped kernel page (once per fragment). For zap / full unmap the error
often self-cancels and looks benign, but **migration does not cancel**: the src
folio is over-removed in `try_to_migrate_one` while the dst folio is over-added in
`remove_migration_pte` (different folios), so the dst is freed with a stale
`_large_mapcount`. This was the intermittent residual (aarch64 PGCL=4 `cow`, ~40%
of boots, order-2/3 mTHP under GUP-pin migration churn; same class as the laptop
corrupt-free page).

Fix: each site detects the **kernel-page edge** from the PTE-table window
(`base = ptep - ((addr >> MMUPAGE_SHIFT) & (PAGE_MMUCOUNT-1))`) and fires exactly
one event per kernel page — **remove on the last present fragment** (scan the
window after clearing; fire iff none remain present), **add/dup on the first
fragment** (scan before installing; fire iff none already present). Refcount/RSS
stay per-MMUPAGE. See `PGCL-RMAP-PRIMITIVES.md` for the full pattern, the five
sites, and the fork `PageAnonExclusive` subtlety. All scans are `#if
PAGE_MMUSHIFT` and collapse to a single-slot (always-fire) window at PGCL=0.

## 7. Notes / known follow-ups (not blockers)

1. **No consumer needs per-MMUPAGE mapcount** (confirmed by audit):
   `folio_mapped`/`page_mapped` are booleans; reclaim/migration want "how many
   mms"; KSM/madvise want mappings. Under Contract A `folio_mapcount(large)`
   returns the mainline value, so `madvise.c` (`folio_mapcount == folio_nr_pages`)
   and the `__folio_large_mapcount_sanity_checks` cap now hold for large folios
   (they were *violated* under per-MMUPAGE counting).
2. **`__wp_can_reuse_large_anon_folio`** compares `folio_large_mapcount` (now
   kernel-page) against `folio_ref_count` (MMUPAGE) — different units under PGCL,
   so it conservatively returns false (COW copies instead of reusing a large
   folio). Correct but a missed optimisation; a Contract-A-aware reuse check is a
   follow-up. The `> folio_nr_pages` WARN there stops firing (it fired under
   per-MMUPAGE counting).
3. **File large folios** under PGCL still use the upstream `folio_pte_batch` path
   (the PGCL per-kernel-page blocks are anon-gated). Not exercised by the
   reproducer; if page-cache large folios appear under PGCL this needs the same
   treatment — tracked as a follow-up.

## 8. Verification

- aarch64 PGCL=4 and =6, un-silenced (DEBUG_VM + DEBUG_VM_PGFLAGS + PAGE_OWNER),
  full LTP (incl. `cow`, `mmap*`, `mprotect*`, `mremap*`): markers → 0, init-ok.
- x86_64 PGCL=4 full LTP still clean (order-0 regression guard).
- x86_64 PGCL=0: Newton limit — no behavioural change (all edits collapse to the
  original code at shift 0).
- Reproducer (`cow` order-2 mTHP freed-while-mapped) gone; no negative
  `_mapcount`/`_nr_pages_mapped` at free.
