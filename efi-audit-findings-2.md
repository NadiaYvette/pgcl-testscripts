# EFI Audit Findings #2 — PGCL Newton-limit violation (bug #106)

Status: FINAL (2026-06-16)

## Bug recap
- x86_64 UEFI laptop, 64GB, fragmented EFI/e820 map.
- PGCL kernel at `CONFIG_PAGE_MMUSHIFT=0` crashes early (PID1/dracut).
- A struct page for a non-RAM/hole/reserved PFN leaks onto the buddy free list;
  `kernel_init_pages` (post_alloc_hook) writes to its direct-map address and faults.
- Faulting PFN ~0xfffeedd38 (~bit 48). This is a NEWTON-LIMIT VIOLATION (shift 0).
- Mainline-base + identical config BOOTS on the same laptop.

## Excluded (do not re-investigate)
1. init_64.c phys_pte_init/phys_pmd_init/phys_pud_init — AND-mask can't set bit 48.
2. Generic e820 handover (memmap_init_range/init_unavailable_range/
   reserve_bootmem_region/__free_pages_core/memblock_free_all) — clean with faithful
   64GB e820 replay under BIOS.
3. OVMF/UEFI QEMU (8GB & 64GB) — clean even with efi_free_boot_services.
4. mm/memblock.c free_reserved_area()/__free_reserved_area() — stock mainline.

## Audit log

### Base / scope
- Base = v7.1 = `8cd9520d35a6`. HEAD = `7e8381ba6621` (branch nadia.chambers/page-clustering-001).
- IMPORTANT: there are 5 UNCOMMITTED working-tree changes, all the same pattern
  (`MMUPAGE_MASK` -> `PHYSICAL_PAGE_MASK` in PTE construction) + a WARN_ONCE:
  arch/x86/mm/{init_64.c,ioremap.c,pgtable.c,pti.c,cpu_entry_area.c}. These are the
  investigator's OWN #106 diagnostics for the phys_pte_init theory that constraint #1
  already excluded. They affect PTE *mapping*, not buddy-free decisions. NOT the leak.

### Files audited and their shift-0 status

**arch/x86/platform/efi/quirks.c** — only ONE PGCL hunk: `efi_unmap_pages()` (commit
2a1ff7fa5628). It re-derives kernel-page count from EFI pages for `kernel_unmap_pages_in_pgd`.
At shift 0: `phys_offset = pa & ~PAGE_MASK` == 0 (EFI regions are 4K-aligned, PAGE_SIZE==4K),
`total_size = num_pages<<12`, `nkpages = DIV_ROUND_UP(total_size, 4096) = num_pages`,
`pa - phys_offset = pa`. => byte-identical to mainline. Also it only unmaps page tables;
does not free to buddy. CLEAN at shift 0.
  - `efi_reserve_boot_services()`, `efi_free_boot_services()`, `efi_arch_mem_reserve()`,
    `efi_mem_reserve()`, `struct efi_freeable_range`, `ranges_to_free`, `free_reserved_area`
    are ALL present byte-identical in the v7.1 BASE (verified `git show BASE:...`). STOCK.
    The reserve (efi_reserve_boot_services -> memblock_reserve(start,size)) and the free
    (efi_free_boot_services -> free_reserved_area) are perfectly paired, both EFI-page
    granular off the SAME md iteration. Cannot leak; identity at shift 0.

**arch/x86/platform/efi/efi.c (x86)** — NO PGCL change (committed or working). `do_add_efi_memmap`
uses EFI_PAGE_SHIFT (invariant). EFI->e820 conversion is mainline. CLEAN.

**drivers/firmware/efi/efi.c, drivers/firmware/efi/memmap.c** — NO PGCL change. CLEAN.

**arch/x86/platform/efi/efi_64.c** — PGCL hunks in `__map_region`, `efi_map_region`,
`efi_update_mappings` (commit 2a1ff7fa5628). All are page-TABLE mapping ops (never free to
buddy). `efi_map_region`: `size = num_pages << EFI_PAGE_SHIFT` (mainline wrongly used
PAGE_SHIFT) — coincides at shift 0. `__map_region`/`efi_update_mappings`: phys_offset==0 at
shift 0, DIV_ROUND_UP collapses to num_pages, `va - phys_offset == va`. Identity at shift 0.

**arch/x86/kernel/e820.c** — ONLY one PGCL hunk in `e820__memblock_setup`, ENTIRELY inside
`#if PAGE_MMUSHIFT` (commit 519f224ce894). Compiles OUT at shift 0. No other e820 hunk.
`e820__end_of_ram_pfn`, `e820__range_*`, EFI/e820 interactions = mainline. CLEAN at shift 0.

**mm/mm_init.c** — only the empty_zero_page change, all `#if PAGE_MMUSHIFT > 0` (commit
b82c0919134e). Compiles OUT at shift 0. NO PGCL change to reserve_bootmem_region /
init_unavailable_range / __init_single_page / memmap_init / init_reserved_page. CLEAN.

**arch/x86/mm/init.c** — three commits:
  - 19af6cfee343 (alloc_low_pages / early_alloc_pgt_buf): PAGE_SIZE->MMUPAGE_SIZE,
    PAGE_SHIFT->MMUPAGE_SHIFT throughout. Identity at shift 0. Allocates page-table pool
    from brk/memblock; never frees a hole page. CLEAN at shift 0.
  - 32b90a749b50 (free_init_pages WARN): at shift 0 takes the
    `PAGE_MMUSHIFT==0 && WARN_ON(...)` branch -> behaviorally identical to mainline
    (WARN then round to PAGE). CLEAN at shift 0.
  - 08e9cb22c5b1 (poking_init text_poke_mm_addr): userspace VA KASLR, MMUPAGE subst.
    Identity at shift 0; not buddy-related. CLEAN.

**mm/memblock.c, mm/page_alloc.c** — NOT in the PGCL diff AT ALL. The entire memblock->buddy
handover, `__free_pages_core`, `post_alloc_hook`/`kernel_init_pages`, free-list management,
and buddy coalescing are 100% STOCK. (Corroborates constraint #2/#4.) The buddy allocator is
faithfully handing out a page that was wrongly placed on its free list by something upstream.

**arch/x86/kernel/setup.c** — NO PGCL change. Kernel/brk/trampoline memblock_reserve = mainline.

**drivers/firmware/efi/mokvar-table.c** — `efi_mokvar_table_init` remap test PAGE_MASK->MMUPAGE_MASK.
Identity at shift 0. UEFI-only but does not free to buddy. CLEAN at shift 0.

**arch/x86/kernel/head64.c** — `clear_page(init_top_pgt)` -> `memset(init_top_pgt, 0,
PTRS_PER_PGD*sizeof(pgd_t))` = memset(...,4096) at shift 0 == clear_page. Identity. CLEAN.

**arch/x86/include/asm/page_types.h** — `PHYSICAL_PAGE_MASK` PAGE_MASK->MMUPAGE_MASK.
At shift 0 MMUPAGE_MASK==PAGE_MASK exactly (both ~(((unsigned long)1<<12)-1)). Identity.

**include/vdso/page.h** — PAGE_SHIFT=MMUPAGE_SHIFT+PAGE_MMUSHIFT; at shift 0 all MMUPAGE_*
macros equal their PAGE_* counterparts exactly (same types/widths, 64-bit branch). No skew.

**arch/x86/include/asm/pgtable.h / pgtable_64.h** — PFN_PTE_SHIFT=MMUPAGE_SHIFT,
page_level_shift uses MMUPAGE_SHIFT, SYM_DATA balign MMUPAGE_SIZE. All identity at shift 0.

**mm/internal.h** — 201 lines but all in PTE-batch / folio-head / vma_address helpers.
No early-init / reserve / buddy-free code. Not relevant to the leak.

**arch/x86/include/asm/page.h, page_64.h; include/asm-generic/memory_model.h; include/linux/pfn.h**
— NO PGCL change. __va/__pa/pfn_to_page/page_to_pfn/page_to_virt = STOCK.

### Deep-dive: precise pfn_pte vs hand-rolled PTE math (the only genuine shift-0 delta)
COMMITTED `phys_pte_init` (init_64.c:508, commit 08e9cb22c5b1) and 4 sibling sites
build a PTE as `__pte((paddr & MMUPAGE_MASK) | pgprot_val(prot))`. Mainline uses
`pfn_pte(paddr >> PAGE_SHIFT, prot)` (pgtable.h:741): `pfn = paddr & PAGE_MASK`,
then `pfn ^= protnone_mask(prot)` (no-op for present kernel PTEs), then
`pfn &= PTE_PFN_MASK` (== PHYSICAL_PAGE_MASK == MMUPAGE_MASK & __PHYSICAL_MASK),
then `| check_pgprot(prot)` (== prot & __supported_pte_mask). At shift 0 the hand-
rolled form differs by THREE omissions: (1) no `& __PHYSICAL_MASK` MAXPHYADDR clamp,
(2) no protnone XOR, (3) raw prot instead of masked. For BOUNDED RAM paddr with sane
prot (PAGE_KERNEL) all three are no-ops -> identity at shift 0. The uncommitted
working-tree edits restore (1) only (MMUPAGE_MASK -> PHYSICAL_PAGE_MASK).
=> This family is a genuine latent Newton violation but, per HARD CONSTRAINT #1 and
the proven-bounded paddr, it cannot ORIGINATE the bit-48 garbage PFN (AND-masking
clears bits, never sets them). It can only AMPLIFY a pre-existing garbage PFN into the
loud reserved-bit fault.

### Linchpin verified: the hole-guard is intact
`pfn_valid` / `for_each_valid_pfn` / present_section / mmzone.h / mm/sparse.c /
sparsemem.h / sparse-vmemmap.c are 100% STOCK (0 diff lines). A hole PFN therefore
CANNOT become "valid" under PGCL. `__free_reserved_area` (mm/memblock.c:898, STOCK)
iterates `for_each_valid_pfn(pfn, PFN_UP(start), PFN_DOWN(end))` -> it SKIPS hole PFNs
and rounds start-up/end-down (frees a subset). So the EFI boot-services free, and
free_init_pages, and free_initmem, structurally CANNOT free a hole page. Confirmed
hole-safe.

### Core free machinery verified stock
free_reserved_page (page_alloc.c:6207), __free_pages, free_pages, folio_put,
__folio_put, free_frozen_pages, free_pages_prepare, __free_pages_core,
free_low_memory_core_early, memblock_free_all, reserve_bootmem_region,
init_unavailable_range, __init_single_page, memmap_init: ALL 100% STOCK (0 diff).
mm/swap.c: 0 diff (the prior flag-masker that was hiding the bad-free at 8G is GONE,
so the bug is NOT being silenced). The corruption is in WHAT page pointer / how many
refs are passed to these stock frees, never in the frees themselves.

### Reconciliation with prior ground-truth (laptop-pgcl0-reserved-bit-free-page.md)
Prior laptop captures (2026-06-16) prove the bug is SIZE-INDEPENDENT: it fires at
pgcl0 (PID1), pgcl4 (PID349 @526s), and is not disproven at pgcl6. Identical signature
each time: reserved-bit #PF in post_alloc_hook -> kernel_init_pages, PTE carrying a
garbage high PFN (`800fffeedd38023`, `800fffedc82f023`). The originating allocation
varies (pgd_alloc, tlb_next_batch, dup_mm) -> a generic allocator hands out a
previously-freed bad page. Prior EFI rounding-symmetry audit (2026-06-16) already
DISPROVED the EFI-reserve-vs-free hypothesis at shift 0; this audit independently
re-confirms and EXTENDS that (full quirks.c/efi_64.c/e820.c/mm_init.c/init.c +
buddy/memblock/sparse/pfn_valid verification). The aarch64 QEMU reproducer (#119)
caught the SAME class: large-folio/THP freed with refcount:0 mapcount:6
(freed-while-mapped -> buddy list -> bad_page on realloc).

### Wider-mm refcount/mapcount/free audit (second pass, 22 files)
A second independent pass over mm/{memory,rmap,huge_memory,migrate,migrate_device,
filemap,gup,swap,swap_state,swapfile,khugepaged,ksm,vmscan,page_vma_mapped,userfaultfd,
shmem,mlock,page_table_check}.c + include/linux/{rmap,mm,pte_cluster}.h + mm/internal.h
found NO suspect at shift 0:
  - The only two `atomic_set(_mapcount, -1)` additions in the WHOLE branch are
    huge_memory.c:3647/3749 (the c7221b452105 fix) and BOTH carry `PAGE_MMUSHIFT > 0 &&`
    guards. No second copy of that bug-class anywhere.
  - huge_memory.c `folio_ref_add(folio, HPAGE_PMD_MMUNR - 1)` == mainline at shift 0
    (HPAGE_PMD_MMUNR == HPAGE_PMD_NR).
  - All COW/anon/zap clustering ref/mapcount math in memory.c is `#if PAGE_MMUSHIFT`-gated
    or collapses to mainline via PAGE_MMUCOUNT==1.
  - rmap.c: pvmw.nr_mmupages==1 at shift 0, every folio_remove_rmap_pte loop runs once,
    folio_put_refs(folio,1)==mainline, early-exit `== folio_nr_pages * PAGE_MMUCOUNT`
    == mainline `== folio_nr_pages`.
  - pte_cluster.h `adjust_page_ref_count` is a `do{}while(0)` no-op in the shift-0 `#else`.
  - filemap.c `filemap_map_pages` is rewritten UNCONDITIONALLY but its three new
    folio_unlock+folio_put sites are unreachable at shift 0 (window stays within one PMD)
    and are correctly ref-balanced even if reached.

### Predicate / accounting audit
NO PGCL change to the mapcount/mapped/ref PREDICATES that stock free paths rely on:
folio_mapcount, page_mapcount, folio_mapped, page_mapped, total_mapcount,
folio_entire_mapcount, _nr_pages_mapped, folio_large_mapcount, folio_ref_count,
folio_expected_ref_count -- all STOCK (0 diff in mm/util.c, mm/rmap.c, include/linux/
{mm,rmap,page-flags,mm_types}.h). So a stock reclaim/migrate/madvise free CANNOT be
tricked into freeing a live page by a wrong predicate.
NO PGCL change to mm/memcontrol.c, mm/vmstat.c, mm/page_owner.c.
mm/madvise.c (the c7221b VICTIM free path): pure MMUPAGE-for-PAGE substitutions +
`folio_pte_batch_flags(...).nr` API widening -- identity at shift 0.
mm/gup.c: MMUPAGE substitutions; `refs` loop restructure preserves the count -- identity.
folio_pte_batch_flags body is byte-identical to mainline in its `.nr` computation
(only the return type widened to a struct; all callers read `.nr`).

### Interim conclusion
Every file in the prescribed EFI/e820/memblock/struct-page-init search list, PLUS the
buddy/memblock/sparse core, the pfn/page/virt conversion macros, the pfn_valid hole-guard,
the wider mm refcount/mapcount/free machinery (22 files), and the mapcount/mapped/ref
predicates, is either STOCK or provably identity at PAGE_MMUSHIFT==0. The prescribed
EFI/e820 surface does NOT contain the leak (confirming the prior 2026-06-16 EFI audit).
Because the bug is size-INDEPENDENT (fires at pgcl0/4/6 alike per the laptop captures),
the originator is NOT a "compiles-differently-at-shift-0" hunk -- it is a logic bug
present at EVERY size, in a path that (a) is exercised by the laptop's real fragmented
firmware map but not QEMU's, and (b) is NOT among the ~40 mm/x86 files audited here.
See Ranked findings + the single most-likely root cause below.

---

# RANKED FINDINGS

Ranking is by likelihood of being the ORIGINATOR of bug #106 (the page wrongly placed
on the buddy free list). "Identity at shift 0" findings are NOT origins but are recorded
because the task asked for the audit verdict on each.

## R0 — PRESCRIBED EFI/e820/memblock/struct-page SURFACE IS CLEAN (negative result)
NOT the origin. There is NO Newton-limit violation and NO reserve-vs-free mismatch in
ANY of the prescribed files. Concretely, all of the following are STOCK or provably
identity at PAGE_MMUSHIFT==0:
  - efi/quirks.c efi_reserve_boot_services / efi_free_boot_services / efi_arch_mem_reserve
    / efi_mem_reserve / ranges_to_free / efi_unmap_boot_services (only efi_unmap_pages is
    PGCL, and it touches page tables not buddy; identity at 0).
  - efi/efi.c, efi_64.c, efi_32.c, drivers/firmware/efi/{efi,memmap}.c (EFI->e820 + map
    install + memmap_insert). efi_64.c hunks are page-table maps, identity at 0.
  - e820.c (only a `#if PAGE_MMUSHIFT` block -> gone at 0).
  - mm/mm_init.c (only `#if PAGE_MMUSHIFT > 0` zero-page -> gone at 0; reserve_bootmem_region
    / init_unavailable_range / __init_single_page / memmap_init / memblock_free_all STOCK).
  - x86/mm/init.c (alloc_low_pages/early_pgt_buf MMUPAGE swaps; free_init_pages identity
    at 0). setup.c unchanged. head64.c memset==clear_page at 0.
  - mm/memblock.c, mm/page_alloc.c, mm/sparse*.c, pfn_valid/for_each_valid_pfn,
    free_reserved_page/__free_pages/folio_put/free_pages_prepare: 100% STOCK.
  - The free machinery is hole-safe: __free_reserved_area uses for_each_valid_pfn +
    PFN_UP(start)/PFN_DOWN(end), which structurally cannot free a hole page.
This independently reconfirms the prior 2026-06-16 "EFI hypothesis disproven at shift 0".

## R1 — (latent, NOT the origin) Group-A hand-rolled PTEs drop pfn_pte() maskings
5 sites build `__pte((paddr & MMUPAGE_MASK) | pgprot_val(prot))` where mainline uses
`pfn_pte(paddr>>PAGE_SHIFT, prot)`, dropping `& __PHYSICAL_MASK` (MAXPHYADDR clamp),
the protnone XOR, and `check_pgprot` (prot & __supported_pte_mask):
  - arch/x86/mm/init_64.c:508 phys_pte_init  (DIRECT-MAP 4K leaf, committed 08e9cb22c5b1)
  - arch/x86/mm/ioremap.c:907 __early_set_fixmap
  - arch/x86/mm/cpu_entry_area.c:90 cea_set_pte
  - arch/x86/mm/pgtable.c:591 native_set_fixmap
  - arch/x86/mm/pti.c:476 pti_clone_user_shared
Working tree already restores the MAXPHYADDR clamp at all 5 (MMUPAGE_MASK ->
PHYSICAL_PAGE_MASK) + a WARN_ONCE at init_64.c:518.
VERDICT: a genuine latent Newton violation that MUST be fixed for postability, BUT per
HARD CONSTRAINT #1 it cannot ORIGINATE the bit-48 garbage PFN -- AND-masking only clears
bits, and phys_pte_init's paddr is bounded by mapped RAM (<= ~bit 36 on this 64GB
laptop). It can only AMPLIFY a pre-existing garbage page into the loud reserved-bit
fault. The init_64.c WARN_ONCE is the right confirmer (see Diagnostic D1).
Recommendation: KEEP the working-tree fix (restore pfn_pte semantics); additionally
restore `check_pgprot(prot)` for full mainline parity, e.g.
`set_pte_init(pte, pfn_pte(paddr >> PAGE_SHIFT, prot), init)` at the 4K leaf (at shift 0
that is literally mainline; at shift>0 pfn_pte's `>>PAGE_SHIFT` then `&PTE_PFN_MASK`
yields the MMUPAGE-granular clamped field, which is what we want).

## R2 — (NOT the origin) wider-mm refcount/mapcount/free, 22 files: clean at shift 0
The c7221b452105 _mapcount bug-class is the right SHAPE (an unguarded struct-page write
that frees/corrupts a live page at shift 0), but a full second-pass audit found NO
remaining instance: the only ungated candidates are already `PAGE_MMUSHIFT > 0`-guarded,
and the predicates (folio_mapped/mapcount/ref_count/expected_ref_count) are all STOCK.
So none of these 22 files originate the bad free at shift 0.

## MOST-LIKELY ROOT CAUSE (single)
The defect is a **freed-while-mapped / wrong-page-pointer free of a struct page**, present
at every PAGE_MMUSHIFT (size-independent), in a code path that the laptop's REAL fragmented
firmware memory map exercises but QEMU's contiguous/OVMF maps do not -- and it is NOT in
the EFI/e820/memblock/struct-page-init surface (R0), NOT the buddy core, and NOT in the
22 mm refcount/free files audited at shift 0 (R2). The page lands on the buddy free list
with a corrupt/garbage struct page; on the next allocation, post_alloc_hook ->
kernel_init_pages writes through its direct-map alias and faults (reserved-bit, because
the fragmented region is direct-mapped at 4K and the page's implied PFN/PTE is garbage).

This is the SAME class the aarch64 QEMU reproducer (#119) already caught: large/THP
folios freed with refcount:0 while still mapped (mapcount>0) -> buddy list -> bad_page on
realloc. The strongest remaining suspects, by elimination, are the LARGE-FOLIO / THP /
migrate / split / device paths whose ref/mapcount bookkeeping differs from mainline in a
way that is NOT `PAGE_MMUSHIFT`-gated -- specifically the "rmap event contract" manual
`atomic_add(nr, &folio->_large_mapcount/_nr_pages_mapped)` accounting in mm/rmap.c and
mm/huge_memory.c, the COW/zap `folio_put_refs(folio, nr)` in mm/memory.c, and
mm/migrate.c remove_migration_pte ref math -- when driven by a partial yield (gaps/edges
of a fragmented mapping), where `nr` can legitimately be < PAGE_MMUCOUNT. A partial-yield
miscount that is correct on contiguous mappings (full PAGE_MMUCOUNT batches, as on QEMU)
but off-by-N at a fragment boundary would be invisible to QEMU and to shift 0's
single-page case, yet still drop a folio refcount to 0 while mapped on the laptop. (Note:
these specific hunks were classified "identity at shift 0" because at shift 0 PAGE_MMUCOUNT
==1 forces nr==1; that means the shift-0 manifestation must instead come from the
predicate/handover interaction above, OR the laptop pgcl0 fault is the AMPLIFIED form of a
page already corrupted before the rmap path -- the PAGE_OWNER capture (D2) will
disambiguate.)

HONEST CAVEAT: with the deterministic surface fully cleared, naming the exact originating
line is not possible from static read alone -- it requires the laptop's real EFI/memmap
(QEMU repro is infeasible per prior work) OR the aarch64 #119 large-folio-mapcount repro.
This audit's value is the DEFINITIVE exclusion of the entire EFI/e820/memblock/struct-page
+ buddy + 22-file mm-refcount surface, which redirects the hunt to the large-folio
ref/mapcount accounting under partial yields and to the live PAGE_OWNER instrument.

## MINIMAL PROPOSED FIX (for the one concrete, verified defect — R1)
Restore mainline pfn_pte semantics at the 5 Group-A sites (the working tree already does
the MAXPHYADDR half). Simplest, provably-mainline-at-0 form for the direct-map leaf:
  arch/x86/mm/init_64.c:521
    -  set_pte_init(pte, __pte((paddr & PHYSICAL_PAGE_MASK) | pgprot_val(prot)), init);
    +  set_pte_init(pte, pfn_pte(paddr >> MMUPAGE_SHIFT, prot), init);
  (pfn_pte already applies `<<PAGE_SHIFT` internally on x86 -- but PFN_PTE_SHIFT/pte_pfn
  use PAGE_SHIFT, so for PGCL>0 correctness pass the MMUPAGE pfn via the existing
  PGCL helper if one exists; at shift 0 `paddr >> MMUPAGE_SHIFT == paddr >> PAGE_SHIFT`
  so it is exactly mainline.) Apply the analogous pfn_pte/check_pgprot restoration to
  cpu_entry_area.c:90, ioremap.c:907, pgtable.c:591, pti.c:476.
This fixes the latent Newton violation and converts any future high-bit paddr into a
clamped PTE (or, with the WARN, a loud diagnostic) instead of a silent reserved-bit page.

## CHEAP DIAGNOSTICS (to confirm on the laptop / crafted repro)
D1 (already staged): the WARN_ONCE at init_64.c:518 fires iff phys_pte_init receives a
paddr above MAXPHYADDR -> tells you whether the direct-map 4K leaf (R1) is actually in
the fault path. If it NEVER fires on the laptop, R1 is confirmed NOT the origin and the
hunt moves entirely to the large-folio/free path.

D2 (decisive, per prior work): un-silenced PAGE_OWNER laptop RPM
(CONFIG_DEBUG_VM + DEBUG_VM_PGFLAGS + PAGE_OWNER, boot `page_owner=on`,
`efi_pstore.pstore_disable=0 oops=panic`). On the laptop the bad free trips
free_page_is_bad and PAGE_OWNER dumps the FREEING stack -> names the exact path that put
the hole/garbage page on the buddy list. This is the single highest-value instrument.

D3 (cheapest new WARN to add — confirms the leak MECHANISM generically): in
post_alloc_hook / kernel_init_pages (mm/page_alloc.c), before the page is zeroed, assert
the page's pfn is real RAM and its direct-map PTE is sane:
    WARN_ONCE(!pfn_valid(page_to_pfn(page)) ||
              page_to_pfn(page) >= max_pfn ||
              !e820__mapped_any(page_to_pfn(page) << PAGE_SHIFT,
                                (page_to_pfn(page) << PAGE_SHIFT) + PAGE_SIZE,
                                E820_TYPE_RAM),
              "PGCL #106: buddy handed out non-RAM/garbage pfn %lx\n",
              page_to_pfn(page));
This fires AT THE HANDOUT (one step before the faulting write), printing the bad pfn and
the allocating stack -- a louder, earlier, KASLR-independent signal than the reserved-bit
oops. Pair with PAGE_OWNER (D2) so the same boot also yields the freeing stack.

