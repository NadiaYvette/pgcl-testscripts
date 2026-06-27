---
name: pgcl-pte-pfn-coordinate-model
description: "How PGCL reconciles PAGE-granular struct-page pfns with MMUPAGE-granular hardware PTEs: the two coordinate systems, why pfn_pte/pte_pfn shift by PAGE_SHIFT while PFN_PTE_SHIFT==MMUPAGE_SHIFT, the two valid PTE-construction idioms, and how sub-PAGE (PAGE-unaligned) pagecache mappings are placed. Reference for explaining/auditing the PTE layer."
metadata:
  node_type: memory
  type: reference
  originSessionId: 443a8d37-2901-482f-b7cd-76625947368f
---

PGCL has TWO pfn coordinate systems; conflating them is the usual source of confusion.
Constants (include/vdso/page.h): `MMUPAGE_SHIFT = CONFIG_PAGE_SHIFT` (hw page),
`PAGE_SHIFT = MMUPAGE_SHIFT + PAGE_MMUSHIFT`, `PAGE_MMUCOUNT = 1<<PAGE_MMUSHIFT`
(MMUPAGEs per kernel page). x86 has NO `__phys_to_pte_val` override → PTE PFN field IS
the physical address (identity); mips (bit 6) / riscv (_PAGE_PFN_SHIFT) override both
`__phys_to_pte_val`/`__pte_val_to_phys`.

## 1. Cluster coordinate (struct-page) vs hardware-frame coordinate
- **Cluster pfn** = `phys >> PAGE_SHIFT` — names one PAGE_SIZE cluster = the unit with
  exactly ONE `struct page`. This is what `page_to_pfn`, `pfn_pte`, `pte_pfn` speak.
- **Hardware frame** = the MMUPAGE-granular physical address the MMU consumes, living in
  the raw PTE bits.

## 2. pfn_pte / pte_pfn use PAGE_SHIFT — and that is correct
- `pfn_pte(page_nr, prot)` = `(page_nr << PAGE_SHIFT) & PTE_PFN_MASK | prot`. Input is a
  cluster pfn; output is the PTE for **sub-page 0** (the cluster's PAGE-aligned base = its
  first MMUPAGE). No sub-page offset to lose — a cluster pfn has none by construction.
- `pte_pfn(pte)` = `(pte_val & PTE_PFN_MASK) >> PAGE_SHIFT` — **intentionally drops** bits
  [MMUPAGE_SHIFT..PAGE_SHIFT) so all PAGE_MMUCOUNT PTEs of a cluster map back to the SAME
  struct page (`pte_page()` → the one owning page). It is a PTE→struct-page software
  projection; **hardware never calls it** (the MMU reads the full physical field, which
  still holds the exact MMUPAGE address). So "dropping" loses nothing hardware needs.

## 3. The fragment/MMUPAGE selection lives in PFN_PTE_SHIFT + set_ptes
- `PFN_PTE_SHIFT = MMUPAGE_SHIFT` (arch/x86/include/asm/pgtable.h:265; mainline = PAGE_SHIFT).
- `pte_advance_pfn(pte,nr) = pte_val + (nr<<PFN_PTE_SHIFT)` = `+ nr*MMUPAGE_SIZE`.
- `set_ptes()` PAGE_MMUSHIFT>0 branch (include/linux/pgtable.h): writes nr PTEs, each
  `pte += __phys_to_pte_val(MMUPAGE_SIZE)` → consecutive hardware frames. **set_ptes does
  NOT force PAGE alignment**; it starts at whatever PTE the caller passes ("nr==1: caller
  already set up sub-page offset").

## 4. Two valid PTE-construction idioms (and the broken one)
- From a struct page / cluster pfn: `pfn_pte(page_to_pfn(page), prot)` (→ sub-page 0) then
  `set_ptes(...,nr)` for the run. (mk_pte = pfn_pte(page_to_pfn(page),prot).)
- From an exact physical address: `__pte(__phys_to_pte_val(paddr & MMUPAGE_MASK) | prot)`,
  iterating `paddr += MMUPAGE_SIZE`. Used by phys_pte_init (direct map), ioremap, fixmap,
  cpu_entry_area, pti — they already hold an MMUPAGE address and map 1:1, bypassing pfn_pte.
- **WRONG (do not):** `pfn_pte(paddr >> MMUPAGE_SHIFT, prot)` → `(paddr>>MMUPAGE_SHIFT)<<
  PAGE_SHIFT = paddr << PAGE_MMUSHIFT` (phys scaled up PAGE_MMUCOUNT×). A 2026-06-16 audit
  proposed this; rejected. See [[laptop-pgcl0-reserved-bit-free-page]].

## 5. Sub-PAGE / PAGE-unaligned pagecache mappings
Unit model: **`vm_pgoff`/`vmf->pgoff` are MMUPAGE-granular** (4KB userspace ABI);
**page-cache/folio index = `pgoff >> PAGE_MMUSHIFT`** (cluster units); sub-page within the
cluster = `pgoff_sub_page_index(pgoff)` = `pgoff & (PAGE_MMUCOUNT-1)` (pagemap.h:1093).
`set_pte_range()` (mm/memory.c) places the correct sub-page:
```c
entry = mk_pte(page, prot);                 // sub-page 0 of cluster `page`
if (PAGE_MMUSHIFT > 0) {
    effective_pgoff = vma->vm_pgoff + ((addr - vma->vm_start) >> MMUPAGE_SHIFT);
    sub = pgoff_sub_page_index(effective_pgoff);
    entry = __pte(pte_val(entry) + __phys_to_pte_val((phys_addr_t)sub * MMUPAGE_SIZE));
}
nr_ptes = (PAGE_MMUSHIFT && nr>1) ? nr*PAGE_MMUCOUNT : nr;   // large folio vs single sub-page
set_ptes(mm, addr, vmf->pte, entry, nr_ptes);
```
So a file mmap'd at e.g. offset 0x1000 (MMUPAGE 1) within a 64KB folio → effective_pgoff
low bits = 1 → entry advanced by 1*MMUPAGE_SIZE → PTE points to folio_base+0x1000. Fully
handles non-cluster-aligned VMAs. Fault-around (mm/filemap.c filemap_map_pages, PGCL
branch ~3757–3948) can't batch across cluster pages (their PTEs are PAGE_MMUCOUNT apart,
violating set_ptes contiguity), so it maps PAGE_MMUCOUNT PTEs per cluster and steps
`vmf->pte += PAGE_MMUCOUNT` per page (filemap_set_ptes_cluster). Partial cluster/VMA edges
→ nr==1 single-sub-page maps (the "partial yield" the rmap contract handles).

See [[user-stack-exec-mmupage-abi]] (vm_pgoff/AT_PAGESZ MMUPAGE ABI) and MEMORY.md
"struct page Layout with PGCL".
