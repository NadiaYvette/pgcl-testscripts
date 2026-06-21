# Direct-Map PTE-Table Stale/Free-Reuse Hunt (Bug #106)

**Status:** COMPLETE (read-only source audit, 2026-06-17)
**Repo:** /home/nyc/src/linux @ nadia.chambers/page-clustering-001, base v7.1
**Constraint honored:** no kernel source edited.

This audit was asked to find the PGCL non-identity-at-0 defect (or lifecycle bug) in the
**direct-map PTE-table free/reuse path** behind bug #106. It builds on (does not repeat)
`efi-audit-findings.md` and `efi-audit-findings-2.md`, and reconciles with the 2026-06-17
text-perfect pstore capture.

---

## TL;DR — ranked conclusion

1. **The entire x86 direct-map PTE-table allocate / fill / free / collapse / split / hot-remove
   lifecycle is either pure-upstream (0 PGCL diff) or provably identity at
   `CONFIG_PAGE_MMUSHIFT==0`.** No PGCL writer can emit the garbage pfn; every kernel PTE-table
   allocator zeroes the full page; the collapse free path is **byte-identical between mainline v7.1
   and PGCL HEAD** (verified by extracting both function bodies). There is **no localizable
   non-identity-at-0 defect in the direct-map PTE-table free/reuse path.**
2. **CRITICAL CORRECTION to the framing:** because the suspect lifecycle code (collapse, split,
   pagetable_free, alloc_low_pages, phys_pte_init) is byte-identical-or-identity-at-0 and
   **mainline boots clean on this exact laptop while PGCL crashes**, the differentiator CANNOT be
   any of these page-table routines directly. The defect is an **INDIRECT** PGCL effect.
3. **NEW load-bearing evidence (my decode of all four pstore captures): the corruption is
   DETERMINISTIC, not random stale data, and the struct page is provably CLEAN.** This reframes
   #106 away from both "freed-and-reused PTE table holding random data" and "bad struct page on the
   freelist". See "Capture decode" — all four corrupt PTEs are *live PAGE_KERNEL leaf PTEs
   (NX|RW|P, Accessed) whose physical field was overwritten with leaked high bits*.
4. **Single most-likely root cause (best available, honestly hedged):** a page that the buddy
   allocator hands to `split_large_page()` to become a **direct-map PTE table** (post-bootmem
   `pagetable_alloc(GFP_KERNEL,0)`) is one that the *wider-mm PGCL bug* (the freed-while-mapped /
   wrong-refcount class, #119) corrupted — OR a stray PGCL store lands in a live direct-map PTE
   table. The 4K-split precondition makes this laptop-only (QEMU direct map is 2M/1G huge pages, so
   `split_large_page` is barely exercised and the IOMMU/SVA + fragmented-map window never opens).
   This is a **timing/data lifecycle bug invisible to static read**, exactly matching every prior
   negative result and the QEMU-can't-reproduce signature.
5. **Confirmation predicate** is already wired (`pgcl106_scan_directmap`, init_64.c:1698,
   late_initcall :1739) but has **not yet been booted/captured** (the scanner RPM exists; the
   3 captured boots predate it). Booting it is the decisive next step — see end.

---

## The bug (from text-perfect pstore, `pstore-pgcl0.txt:278-324`, nokaslr)

```
BUG: ... address: ffff8881302e9000   #PF error 0x000b (reserved bit), supervisor WRITE
PGD 8c01067 P4D 8c01067 PUD 128eee063 PMD 133ad4063 PTE 800ffffecfd16023
RIP: kernel_init_pages+0x36/0x50        (rep stosq zeroing one 4K page; RCX=0x1000)
RDI=ffff8881302e9000  RDX/R12=ffffea0004c0ba40  RSI=ffffea0004c0ba80  CR3=1336e2006 (NOPTI)
Call Trace: post_alloc_hook -> get_page_from_freelist -> __alloc_frozen_pages_noprof
            -> alloc_pages_mpol -> alloc_pages_noprof -> pte_alloc_one -> __pte_alloc
            -> do_anonymous_page -> handle_mm_fault   (user fault, loadkeys PID356)
```
pgcl4 capture (`pstore-pgcl4.txt:148-198`): identical class, page allocated via **pgd_alloc**
(pgcl0 via pte_alloc_one; an earlier pgcl4 via tlb_next_batch) → the bad page's *consumer varies*,
so the corruption is a property of the **physical page**, not the allocation site.

### Register decode (my analysis — the decisive new read)
- `RDX/R12 = ffffea0004c0ba40` is a vmemmap `struct page *`. `(offset 0x4c0ba40)/64 = 0x1302e9`
  = **exactly the faulting pfn**. The struct page is the correct one for pfn `0x1302e9` and is
  **CLEAN** — the un-silenced DEBUG_VM+PAGE_OWNER build issued NO Bad-page report.
- `RDI = __va(0x1302e9<<12) = ffff8881302e9000` (PAGE_OFFSET `0xffff888000000000`). The page is
  **real RAM at 4.75 GiB**, pfn real and `< max_pfn`.
- `PMD 133ad4063` = a 4K PTE-table at phys `0x133ad4000`, **no PSE** → a 4K-split direct-map
  region. `pte_index(VA)=233` → slot `0x133ad4748` holds the garbage `PTE 800ffffecfd16023`.

⇒ #106 is a **corrupt direct-map LEAF PTE on a 4K-split region of REAL RAM**. The page handed out
is fine; only its direct-map alias is corrupt; `kernel_init_pages` faults zeroing the page via that
alias. (This supersedes the "bad freelist page" framing the EFI/memblock/handover audits chased —
those audits remain correct *negatives*, but for the wrong target.)

## Capture decode — DETERMINISTIC injection, not random stale data

| capture | corrupt PTE | flags | NX | pfn field | sign-extended |
|---|---|---|---|---|---|
| pgcl0 06-17 | `0x800ffffecfd16023` | `0x023` P\|RW\|A | 1 | `0x00ffffecfd16` | `0xfffffffecfd16023` |
| pgcl4 06-17 | `0x800ffffed713f023` | `0x023` P\|RW\|A | 1 | `0x00ffffed713f` | `0xfffffffed713f023` |
| pgcl0 06-16 | `0x800fffeedd38023`  | `0x023` P\|RW\|A | 0 | `0x000fffeedd38` | `0xfffffffeedd38023` |
| pgcl4 06-16 | `0x800fffedc82f023`  | `0x023` P\|RW\|A | 0 | `0x000fffedc82f` | `0xfffffffedc82f023` |

- **Identical flag byte `0x023` (P + RW + Accessed) in all four.** Random stale memory would show
  random low bits. The **Accessed bit set** means the CPU page-walker actually consumed the slot →
  it was a *live, valid* PTE.
- All four sign-extend into `0xfffffffe_……` = the **top-2 GiB kernel-text/module/fixmap VA band**
  → the injected bits look like a **leaked kernel VA / code-or-data pointer**, not a mis-computed
  phys pfn.

Interpretation: these are **PAGE_KERNEL direct-map leaf PTEs whose physical field was OR'd/
overwritten with high bits from a leaked 64-bit kernel value** — the signature of an **in-place
64-bit store landing in a live direct-map PTE-table slot**, NOT of an un-zeroed or freed-as-data
page (which would not preserve `0x023`+A).

---

## Audited and ELIMINATED (identity-at-0 or pure-upstream)

PGCL delta since v7.1 = **6 commits** only: `08e9cb22c5b1`, `32b90a749b50`, `69be8199a673`,
`07360c1a0250`, `19af6cfee343`, `9a8ed4eba11d`.

### Direct-map PTE-table FREE/REUSE path (the prescribed target) — all clean
- `cpa_collapse_large_pages` (set_memory.c:413), `collapse_pmd_page` (:1275), `collapse_pud_page`
  (:1345), `collapse_large_pages` (:1400): **NOT PGCL-modified.** `cpa_collapse_large_pages` and
  `split_large_page` are **byte-identical v7.1↔HEAD** (verified). Free ordering is correct &
  upstream: `set_pmd`/`set_pud` detach → `flush_tlb_all()` (line 437) → `pagetable_free()`
  (line 441). Identity at 0. **Cannot be the PGCL differentiator.**
- `pagetable_alloc`/`pagetable_free`/`__pagetable_free`/`pagetable_free_kernel`/`PT_kernel`/
  `ptdesc_set_kernel`/`ptdesc_test_kernel` — **0 PGCL diff** (include/linux/mm.h,
  mm/pgtable-generic.c). `__pte_alloc_one_kernel` uses `GFP_PGTABLE_KERNEL=GFP_KERNEL|__GFP_ZERO`
  → kernel PTE tables fully zeroed.
- `CONFIG_ASYNC_KERNEL_PGTABLE_FREE` / `kernel_pgtable_work_func` / `iommu_sva_invalidate_kva_range`
  (mm/pgtable-generic.c:413-449) — **0 PGCL diff**, upstream (commits 5ba2f0a15564, e37d5a2d60a3).
  Enabled on the laptop (`CONFIG_IOMMU_SVA=y`). See "Note on the async-free path" below.
- `free_pte_table`/`free_pmd_table`/`remove_pte_table`/`remove_pagetable` (init_64.c:1022-1430) —
  UNCHANGED from mainline; hot-remove only, not on the boot allocation path.
- `__split_large_page` (set_memory.c:1145): fill loop writes **all 512** entries (line 1212), each
  clamped `__pte((paddr & PTE_PFN_MASK)|prot)` (line 1138); at shift 0 byte-identical to mainline
  `pfn_pte`. `split_large_page`'s `pagetable_alloc(GFP_KERNEL,0)` is NOT `__GFP_ZERO`, but identical
  to mainline and harmless (all 512 overwritten). Identity at 0.
- `populate_pte`/`populate_pgd` + `alloc_pte_page` (EFI alt-pgd, not direct map): `__GFP_ZERO`
  table, bounded clamped fill (`num_mmu_pages=num_pages<<PAGE_MMUSHIFT`==num_pages at 0). Clean.
- `phys_pte_init` 4K leaf (init_64.c:483-522, commit 9a8ed4eba11d): clamped + WARN_ONCE; identity
  at 0; **WARN proven silent on all 3 laptop captures** ⇒ this builder does NOT write the garbage.
- `alloc_low_pages` (init.c:126): `memset(adr,0,MMUPAGE_SIZE)`==`clear_page` at 0, pool fully
  zeroed, all pfn/size arithmetic identical at 0.

### Non-CPA direct-map writers — clean (sub-agent + my reads)
`__set_pages_np/p`, `set_direct_map_invalid/default/valid_noflush`, `__kernel_map_pages` — unchanged
wrappers; KASAN (`mm/kasan/*`, `arch/x86/mm/kasan_init_64.c`), mem_encrypt
(`arch/x86/mm/mem_encrypt*.c`, `__set_memory_enc_pgtable`), debug_pagealloc callers — **0 PGCL
diff**. `__change_page_attr` 4K in-place block (set_memory.c:1894): `for(sub=0;sub<PAGE_MMUCOUNT;…)`
runs once at 0, pfn via `phys & PTE_PFN_MASK` (clamped), `cpa->numpages=1`. Identity at 0; clamped →
cannot inject high bits.

### Generic mm lifecycle / page_alloc / memblock / sparse — pure upstream
`mm/page_alloc.c`, `mm/memblock.c`, `mm/sparse*.c`, `mm/memory_hotplug.c`, `mm/sparse-vmemmap.c`,
`mm/memory.c` page-table teardown (`free_pgtables`/`free_pte_range`/`__pte_free_tlb`/
`tlb_finish_mmu`), `__pte_alloc`/`__pte_alloc_kernel`/`pmd_install` — byte-identical to v7.1.
hole-guard (`pfn_valid`/`for_each_valid_pfn`) intact.

### vmalloc / ioremap / realmode / EFI / e820 / fixmap — identity-at-0 or gated
- `mm/vmalloc.c` (110 lines): `vmap_pte_range`/`vunmap_pte_range`/`vmap_pages_pte_range` write
  **vmalloc-space** PTEs (`set_pte_at(&init_mm, addr in vmalloc range, …)`), via
  `__pte(__phys_to_pte_val(paddr)|prot)` (x86 `__phys_to_pte_val`=identity). The faulting VA is in
  the **direct map** (`ffff8881…`), not vmalloc (`ffffc900…`), so these never land in the
  direct-map tables. Identity at 0 (`for(sub…)` runs once).
- `arch/x86/kernel/e820.c` low-1M re-add — entirely `#if PAGE_MMUSHIFT` → compiled OUT at 0.
- `arch/x86/platform/efi/*` — page-table maps on `efi_mm`/alt-pgd only; never the kernel direct map
  or buddy; identity at 0; reserve/free byte-identical upstream.
- `arch/x86/realmode/*` (158 lines): explicit `if (PAGE_MMUSHIFT==0)` branch does exactly mainline;
  W+X is the `else` (PGCL>0, sibling bug #129). `arch/x86/kernel/setup.c` — 0 PGCL diff.
- `arch/x86/mm/ioremap.c`, `arch/x86/mm/pgtable.c` (`native_set_fixmap`), `cpu_entry_area.c`,
  `pti.c` hand-rolled PTEs — clamped (PHYSICAL_PAGE_MASK), fixmap/cea/pti not direct-map, identity
  at 0.
- `include/linux/pgtable.h` `set_ptes` `#else` (shift-0) branch is verbatim mainline;
  `pte_advance_pfn` adds `nr<<PFN_PTE_SHIFT` unmasked but `PFN_PTE_SHIFT==12` at 0 (the
  additive-overflow mechanism the signature *resembles*, but used for user/vmalloc maps, not the
  direct map, and identity at 0). `include/linux/pte_cluster.h` (NEW) — userspace clusters only
  (NULL mm), `do{}while(0)` no-ops at 0.

### Note on the async-free path (a real but NON-differentiating gap)
The collapse free path (`cpa_collapse_large_pages`→`pagetable_free`) frees collapsed direct-map
PTE-table pages that are **never marked PT_kernel**, so `pagetable_free` takes the synchronous
`__pagetable_free` branch and **skips `iommu_sva_invalidate_kva_range`** (the SVA IOTLB flush).
This *looks* like a route by which a still-cached IOMMU IOTLB entry could write a stale value into a
recycled table. **BUT this code is byte-identical to mainline v7.1**, and mainline boots clean on
this laptop — so by itself it CANNOT be the PGCL differentiator (it would crash mainline too). It is
at most an upstream gap that a PGCL change could *trigger more often*; it is not #106's root. (Filed
here so it is not re-derived as a fresh lead.)

---

## RANKED candidate mechanisms

### R1 (TOP) — a buddy page that BECOMES a direct-map PTE table is corrupted by the wider-mm PGCL bug
- Post-bootmem, direct-map PTE tables come from `split_large_page` →
  `pagetable_alloc(GFP_KERNEL,0)` → the **buddy allocator**. If PGCL's wider-mm defect (the
  freed-while-mapped / wrong refcount / mapcount class — the #119 aarch64 reproducer; manual
  `atomic_add` rmap accounting, `folio_put_refs`, partial-yield miscounts) lets a page reach the
  buddy freelist while it is *still referenced elsewhere*, that page can be handed to
  `split_large_page` as a PTE table **and** be concurrently written by its other (stale) owner →
  a live direct-map PTE-table slot gets a leaked 64-bit value with valid-looking flags. This fits:
  deterministic `0x023`+A (the slot was a real, walked PTE), leaked-pointer high bits (the other
  owner's data), 4K-split (only `split_large_page` allocs these from buddy), laptop-only (QEMU's
  direct map is 2M/1G so `split_large_page` is barely used and the fragmented-map + IOMMU-SVA
  window never opens), shift-independent (fires at 0/4/6).
- **Why static-invisible:** the page-table code is correct; the corruption is in *which* page the
  buddy hands out and *who else still writes it* — a refcount/lifetime bug, not a pgtable bug.
- **Caveat / open tension:** the #119 class is "identity at shift 0" (PAGE_MMUCOUNT==1 ⇒ nr==1), so
  the *exact* #119 sub-bug may not fire at pgcl0. Either (a) a sibling refcount path is NOT
  shift-gated, or (b) one prior "identity at shift 0" classification is subtly wrong. The
  PAGE_OWNER capture (below) settles this by naming the *freeing* stack of the corrupt page.

### R2 — a stray PGCL 64-bit store into a live direct-map PTE table (aliasing / wrong pointer)
The injected bits look like a leaked kernel VA. A PGCL change that writes a pointer into a page that
is simultaneously a direct-map PTE table would do it. PGCL did NOT change `__va`/`__pa`/
`page_to_pfn`/`pmd_page_vaddr` (all unit-correct at 0), so a PGCL-introduced alias is not visible
statically. Lower probability than R1 but consistent with the leaked-pointer signature.

### R3 (ELIMINATED as origin) — un-zeroed / freed-as-data PTE table
The consistent `0x023`+Accessed rebuts "stale uninitialized data". Every kernel PTE-table allocator
zeroes; `__split_large_page` fills all 512. Not the origin of *this* signature.

### R4 (ELIMINATED at 0; collapse async-free gap) — see "Note on the async-free path"
Byte-identical to mainline ⇒ cannot be the differentiator. Real but not the root.

### R5 (ELIMINATED at 0; KEEP as hygiene) — Group-A hand-rolled PTEs dropping pfn_pte clamp
5 sites now use PHYSICAL_PAGE_MASK; identity at 0; AND-masking only clears bits → cannot ORIGINATE
high pfn; WARN proven silent. Keep for postability; not #106's origin.

---

## Honest assessment

Three independent passes (this audit + the two prior) agree: **the x86 direct-map PTE-table
free/reuse path contains no non-identity-at-0 defect and no non-clamping writer; the suspect
collapse/free code is byte-identical to mainline.** Combined with the multi-capture decode (a
*deterministic high-bit injection into live PAGE_KERNEL leaf PTEs on 4K-split regions, laptop-only,
shift-independent*, over a *clean* struct page), the coherent explanation is **not** a localizable
page-table line but an **indirect lifetime/data corruption of a page that becomes a direct-map PTE
table** (R1), whose trigger set (4K splits + buddy-sourced PTE tables + IOMMU-SVA + fragmented
firmware map + the wider-mm refcount churn) exists only on the laptop. Static read is exhausted; the
decisive instrument is runtime.

---

## CONFIRMATION PREDICATE (what to do on the next laptop boot)

The scanner already exists and is the right tool, but **was not present/captured in the 3 booted
images** — boot the scanner RPM first. `pgcl106_scan_directmap()` (arch/x86/mm/init_64.c:1698;
late_initcall :1739) prints, for every present 4K direct-map leaf with `pfn>=max_pfn`:
```
PGCL#106[late_initcall] bad dmap leaf @ <VA> = <PTEval> pfn <p> >= max_pfn <m>
PGCL#106[late_initcall] direct-map scan: <N> 4K leaves, <B> bad
```
Decision tree (nokaslr build):
- **B>0 at late_initcall** ⇒ the corrupt leaf is present & persistent (created before
  late_initcall). Re-confirm the signature: `<PTEval>` should again be `flags 0x023` + a `0xfff…`
  pfn. Note the containing-PMD phys (`<VA>` → walk).
- **To prove/refute R1 (corrupt buddy page → PTE table):** add a one-line trace in
  `split_large_page` (set_memory.c:1256) logging `page_to_phys(ptdesc_page)` of each newly
  allocated PTE table, plus the existing PAGE_OWNER (`page_owner=on`) on the corrupt page. If a
  `bad dmap leaf`'s PMD phys matches a page that `split_large_page` recently took from buddy AND
  PAGE_OWNER shows that page was *freed* by an mm refcount path (rmap/THP/migrate/zap) just before,
  R1 is proven. The PAGE_OWNER *freeing stack* names the exact wider-mm originator.
- **B==0 at late_initcall but the fault still occurs later** ⇒ corruption created after
  late_initcall (runtime module/BPF `set_memory_rox` collapse, or an SVA IOTLB event) → hook the
  scan into `set_memory_rox` return or a periodic timer.

### Proposed concrete next experiments (no fix is yet justified as root)
1. **Boot the scanner+PAGE_OWNER RPM** with
   `nokaslr page_owner=on efi_pstore.pstore_disable=0 oops=panic` → get (a) scanner B/VA/PTE, (b)
   PAGE_OWNER freeing stack of the corrupt page, (c) the real oops. This single boot decides R1 vs
   R2 and names the originator.
2. If R1 is implicated, the **wider-mm refcount fix** (the #119 rmap-event-contract / partial-yield
   accounting) is the real fix — NOT a change in the (byte-identical, correct) direct-map
   page-table code.

(No source-level fix is proposed for the page-table path because none is defective. The one
genuinely-improvable item — routing collapse-freed direct-map tables through the IOMMU-SVA-aware
`pagetable_free_kernel` — is an *upstream* hardening, byte-identical-to-mainline today, and would
need to be proposed upstream; it is not #106's PGCL root cause.)
