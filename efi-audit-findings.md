# EFI / direct-map reserved-bit-fault audit (task #106)

**Status: COMPLETE** — root cause identified (init_64.c:508), Newton-limit violation proven, fix proposed.

## Bug summary
- x86_64 UEFI laptop (64GB, fragmented firmware map), PGCL kernel built `CONFIG_PAGE_MMUSHIFT=0`.
- Reserved-bit page fault (error_code 0x0b) writing a direct-map address in `kernel_init_pages` (post_alloc_hook), on a page just handed out by the buddy allocator.
- Faulting PTE carries GARBAGE high PFN (e.g. 0xfffeedd38 ~281TB > MAXPHYADDR → reserved bit set).
- `PAGE_MMUSHIFT==0` ⇒ NEWTON-LIMIT VIOLATION: some PGCL change differs from mainline even at shift 0.
- Mainline-base + identical config BOOTS on the same laptop; PGCL tree does not.
- Reproduces ONLY on laptop real UEFI map (QEMU BIOS+64GB e820 clean; OVMF 8GB/64GB clean).

## Already ruled out (not re-audited)
- mm/memblock.c free_reserved_area / __free_reserved_area — stock mainline.
- The EFI free path frees the page UNTOUCHED (poison=-1); corruption is in the page's DIRECT-MAP PTE built earlier.

## Laptop geometry of interest
- Lone 4KB System-RAM page at phys 0x8d7ff000 (Reserved on both sides).
- True holes e.g. 0x96000000-0x973fffff.

---

## Findings (incremental)

### [#1 — ROOT CAUSE, HIGH CONFIDENCE] arch/x86/mm/init_64.c:508 — phys_pte_init drops PTE_PFN_MASK (high-physical-bit clamp). NOT identity at shift 0.

**File:line:** `arch/x86/mm/init_64.c:508` (introduced by commit `08e9cb22c5b1`, the main PGCL forward-port).

**The change:**
```c
// mainline:
set_pte_init(pte, pfn_pte(paddr >> PAGE_SHIFT, prot), init);
// PGCL:
set_pte_init(pte, __pte((paddr & MMUPAGE_MASK) | pgprot_val(prot)), init);
```

This is the **PTE-level direct-map builder**. `phys_pmd_init` / `phys_pud_init` huge-page
branches still use the unmodified `pfn_pmd()`/`pfn_pud()` (which DO apply the physical mask);
only the 4KB PTE leaf path was hand-rolled. The lone-sub-2MB-RAM-fragment case on a
fragmented UEFI map falls precisely to this 4KB leaf path.

**What mainline `pfn_pte(paddr >> PAGE_SHIFT, prot)` does** (arch/x86/include/asm/pgtable.h:741):
1. `pfn = (paddr >> PAGE_SHIFT) << PAGE_SHIFT`  — clears low 12 bits (round down to page).
2. `pfn ^= protnone_mask(pgprot_val(prot))`     — protnone inversion (0 for present entries).
3. `pfn &= PTE_PFN_MASK`                          — **clears all bits at/above MAXPHYADDR** (and flag bits).
4. `__pte(pfn | check_pgprot(prot))`             — masks prot to `__supported_pte_mask`.

`PTE_PFN_MASK` = `PHYSICAL_PAGE_MASK` = `((signed long)MMUPAGE_MASK) & __PHYSICAL_MASK`
(arch/x86/include/asm/pgtable_types.h:285, page_types.h:16). `__PHYSICAL_MASK` =
`physical_mask` = `(1<<MAXPHYADDR)-1` (dynamic) or `(1<<52)-1` static. **It clears the high bits.**

**What the PGCL line does:** `(paddr & MMUPAGE_MASK) | pgprot_val(prot)`. `MMUPAGE_MASK` =
`~(MMUPAGE_SIZE-1)` (include/vdso/page.h:28) — clears ONLY the low MMUPAGE_SHIFT bits (12 at
shift 0). It **never clears the high bits above MAXPHYADDR**. Steps 2/3/4 above are all gone.

**Newton-limit verdict — NOT identity at CONFIG_PAGE_MMUSHIFT==0.** At shift 0,
`MMUPAGE_MASK == PAGE_MASK == ~0xFFF`, so `paddr & MMUPAGE_MASK` keeps every bit of `paddr`
above bit 11. Mainline additionally `&= PTE_PFN_MASK`, clearing every bit at/above MAXPHYADDR.
**If `paddr` carries any bit set above the CPU physical-address width, the two expressions
produce DIFFERENT PTEs even at shift 0.** That is a Newton-limit violation by definition.

**Why it produces the exact bug signature (garbage high PFN 0xfffeedd38 → reserved bit set):**
- The faulting PFN `0xfffeedd38` corresponds to byte address `0xfffeedd38000`, which has bits up
  to bit ~47 set — above a 46-bit MAXPHYADDR (i7-1370P class).
- Mainline: `0xfffeedd38000 & PTE_PFN_MASK` (MAXPHYADDR=46) → clears bits ≥46 → legal PFN, no fault.
- PGCL: `0xfffeedd38000 & MMUPAGE_MASK` → unchanged → PTE PFN field = `0xfffeedd38` → bits 46/47
  are RESERVED on this CPU ⇒ **reserved-bit page fault (error_code 0x0b)** on first access to that
  direct-map page (exactly post_alloc_hook → kernel_init_pages zeroing the page).

**Why only the laptop / only the real UEFI map:** the direct map is built from memblock ranges
(`init_mem_mapping → init_range_memory_mapping → init_memory_mapping → kernel_physical_mapping_init
→ phys_p4d/pud/pmd/pte_init`). `paddr` descends via repeated `__pa(__va(...))` round-trips and
`PFN_PHYS()`/`round_up`/`round_down` against P*D_MASK — **none of which re-clamp the high physical
bits**; the ONLY high-bit clamp in the whole descent was inside `pfn_pte` itself, which PGCL
deleted. A fragmented 64GB UEFI map presents region bases / sub-2MB fragments (and/or non-canonical
`__pa`/`__va` round-trips near holes) whose value carries high bits; QEMU's clean low contiguous
e820 never does. Hence laptop-only, real-UEFI-only — matching all the ruled-out QEMU results.

**Confidence the prot bits are NOT the trigger:** for the direct map `prot == PAGE_KERNEL`, which is
already pre-masked `& __default_kernel_pte_mask`, so dropping `check_pgprot()` adds no stray flag
bits, and `protnone_mask()` is 0 for present entries. So differences (b)/(c)/(d) collapse to no-ops
here; **(a) the high-PFN clamp is the sole effective divergence** — which is exactly the reported
garbage-high-PFN reserved-bit fault. (b)/(c)/(d) remain latent correctness gaps for non-PAGE_KERNEL
callers but are not this bug.

**Proposed minimal fix (Newton-safe, preserves PGCL MMUPAGE granularity):**
```c
set_pte_init(pte, __pte((paddr & PHYSICAL_PAGE_MASK) | check_pgprot(prot)), init);
```
`PHYSICAL_PAGE_MASK` is already `(signed long)MMUPAGE_MASK & __PHYSICAL_MASK` — simultaneously
MMUPAGE-granular AND MAXPHYADDR-clamped, the exact mask `pfn_pte` applies. `check_pgprot(prot)`
restores the supported-pte masking. At shift 0 this is byte-identical to mainline `pfn_pte`
(modulo the missing protnone xor / shadow-stack WARN, both no-ops for present PAGE_KERNEL). NOTE:
do NOT "fix" by calling `pfn_pte(paddr >> MMUPAGE_SHIFT, prot)` — `pfn_pte` shifts internally by
`PAGE_SHIFT`, so under PGCL>0 that double-counts the cluster shift. The explicit-mask form above
is the correct PGCL-aware form.

---

### [CLEAN] arch/x86/mm/init_64.c:1273/1568 — vmemmap_free/populate VM_BUG_ON relaxation (commit 39ab9d2c3fb6)

`VM_BUG_ON(!PAGE_ALIGNED(start/end))` → `VM_BUG_ON(!IS_ALIGNED(start/end, MMUPAGE_SIZE))`.
DEBUG_VM-only assertion. At shift 0 `MMUPAGE_SIZE == PAGE_SIZE`, so identical. Cannot affect a
non-DEBUG_VM build and cannot write a PTE. **Identity at shift 0. Not the bug.**

---

### [CLEAN] arch/x86/platform/efi/quirks.c — EFI reserve/free path and efi_unmap_pages (commit 2a1ff7fa5628)

- `efi_reserve_boot_services` / `efi_unmap_boot_services` (builds `ranges_to_free`) /
  `efi_free_boot_services`: **STOCK MAINLINE, no PGCL edits.** Reserve and free BOTH use
  `md->num_pages << EFI_PAGE_SHIFT`. No reserve-vs-free rounding/coalescing mismatch; nothing frees
  a non-RAM/sub-PAGE/hole region. `can_free_region` gates on `e820__mapped_all(...E820_TYPE_RAM)`.
- The one PGCL hunk is in `efi_unmap_pages` (UNMAPS EFI runtime mappings in `efi_mm.pgd`, NOT the
  direct map, NOT the buddy free). Verified identity at shift 0: md->phys_addr is EFI-page (4KB)
  aligned so `phys_offset = pa & ~PAGE_MASK == 0`; `nkpages = DIV_ROUND_UP(num_pages<<12, 4096) ==
  num_pages`; `pa - 0 == pa`, `va - 0 == va` ⇒ reduces to mainline `kernel_unmap_pages_in_pgd(pgd,
  pa/va, num_pages)`. Operates on efi_mm, so cannot create a direct-map reserved-bit PTE anyway.
  **Identity at shift 0. Not the bug.**

---

### [CLEAN] mm/sparse-vmemmap.c, mm/sparse.c — NO PGCL edits at all (verified `git log <base>..HEAD`). Not the bug.

### [CLEAN] arch/x86/mm/init.c — alloc_low_pages/early_pgt_buf (commits 19af6cfee343, 32b90a749b50, 08e9cb22c5b1)

All edits are PAGE_SHIFT/PAGE_SIZE → MMUPAGE_SHIFT/MMUPAGE_SIZE in `alloc_low_pages`,
`early_alloc_pgt_buf`, `INIT_PGT_BUF_SIZE`, and `clear_page`→`memset(...,MMUPAGE_SIZE)`.
At shift 0 MMUPAGE_*==PAGE_*, so all identity. `init_memory_mapping` / the mapping-range loop /
`memory_map_top_down`/`bottom_up`/`init_range_memory_mapping` are otherwise stock and do NOT
re-clamp high physical bits — they merely PASS `paddr` down to the broken leaf. Not themselves the
bug, but they are why a high-bit `paddr` reaches init_64.c:508 unmasked.

---

### [CLEAN at shift 0] arch/x86/platform/efi/efi_64.c — __map_region / efi_map_region / efi_update_mappings (commit 2a1ff7fa5628)

All three operate on the **EFI runtime pgd** (`kernel_map_pages_in_pgd`), NOT the direct map.
Verified each reduces to mainline at CONFIG_PAGE_MMUSHIFT==0 (md->phys_addr is 4KB/EFI-page
aligned ⇒ `phys_offset = md->phys_addr & ~PAGE_MASK == 0`; `DIV_ROUND_UP(num_pages<<EFI_PAGE_SHIFT,
PAGE_SIZE) == num_pages`; `num_pages<<EFI_PAGE_SHIFT == num_pages<<PAGE_SHIFT`; addresses minus 0
unchanged). The `<<PAGE_SHIFT → <<EFI_PAGE_SHIFT` fix only diverges at shift>0 (the 16x-inflation
bug they fixed). **Identity at shift 0. Cannot touch the direct map. Not the #106 bug.**

---

### [LATENT CLASS — same dropped-mask pattern, NOT the #106 trigger but same Newton-limit class]

The main PGCL commit `08e9cb22c5b1` mechanically rewrote EVERY `pfn_pte(x >> PAGE_SHIFT, prot)`
into `__pte((x & MMUPAGE_MASK) | pgprot_val(prot))`, dropping `PTE_PFN_MASK` + `check_pgprot` +
`protnone_mask` in all of them. Confirmed sites (mainline `pfn_pte(...)` → PGCL `__pte((x &
MMUPAGE_MASK)|pgprot_val(...))`):
- `arch/x86/mm/init_64.c:508` — phys_pte_init (direct map) ← **the #106 trigger** (firmware paddr).
- `arch/x86/mm/cpu_entry_area.c:90` — cea_set_pte (pa = controlled kernel/percpu phys).
- `arch/x86/mm/ioremap.c:907` — __ioremap_caller leaf (phys = driver MMIO; high-bit MMIO could in
  principle trip the same reserved-bit issue on some HW, but unrelated to #106's RAM direct map).
- `arch/x86/mm/pgtable.c:591` — __native_set_fixmap (phys = fixmap target, controlled).
- `arch/x86/mm/pti.c:476` — pti_clone leaf (pa = kernel phys, controlled).

These four (cpu_entry_area/pgtable/pti, and ioremap for normal low MMIO) take inputs that never
carry above-MAXPHYADDR bits in practice, so they don't fire #106 — but they are the SAME
non-identity-at-0 defect and should ALL be fixed with the `PHYSICAL_PAGE_MASK | check_pgprot`
form for correctness/robustness. NOTE `init_64.c:417` (`__pmd(phys|pgprot_val(prot))` in
`__init_extra_mapping`) is STOCK MAINLINE (Jack Steiner 2008), not PGCL — leave it.

NOTE: `phys_pmd_init` (2M), `phys_pud_init` (1G), `phys_p4d_init` are BYTE-IDENTICAL to mainline
(the PGCL commit has only 2 hunks in init_64.c, both inside phys_pte_init) and still use
`pfn_pmd`/`pfn_pud`, which DO apply `PHYSICAL_PMD/PUD_PAGE_MASK`. So the huge-page direct-map
entries are correctly clamped; only the 4KB leaf is broken — and a lone sub-2MB UEFI RAM fragment
is exactly what reaches that 4KB leaf.

---

## RANKED CONCLUSION

1. **[ROOT CAUSE]** `arch/x86/mm/init_64.c:508` `phys_pte_init` — `__pte((paddr & MMUPAGE_MASK) |
   pgprot_val(prot))` dropped mainline `pfn_pte`'s `PTE_PFN_MASK` (high-physical-bit / MAXPHYADDR
   clamp). NOT identity at CONFIG_PAGE_MMUSHIFT==0 ⇒ Newton-limit violation. When a fragmented
   real-UEFI map feeds a `paddr` carrying bits above MAXPHYADDR (sub-2MB fragment near holes /
   non-canonical `__pa`/`__va` round-trip) to the 4KB direct-map leaf, those bits land verbatim in
   the PTE's PFN field → reserved-bit set → reserved-bit fault (0x0b) when post_alloc_hook zeroes
   the page. Garbage PFN 0xfffeedd38 = `0xfffeedd38000 & MMUPAGE_MASK` unmasked. QEMU's clean low
   e820 never supplies such a paddr ⇒ laptop/real-UEFI-only. **Fix:**
   `set_pte_init(pte, __pte((paddr & PHYSICAL_PAGE_MASK) | check_pgprot(prot)), init);`

2. **[LATENT, same class]** cpu_entry_area.c:90, ioremap.c:907, pgtable.c:591, pti.c:476 — identical
   dropped-mask rewrite; fix all to the `PHYSICAL_PAGE_MASK | check_pgprot` form. Not #106, but
   should be corrected (esp. ioremap.c for high MMIO).

3. **[CLEAN]** quirks.c reserve/free path (stock mainline, no reserve/free mismatch), quirks.c
   efi_unmap_pages, efi_64.c map hunks, init_64.c vmemmap asserts, init.c alloc_low_pages,
   mm/sparse*.c (no edits). All identity at shift 0 and/or not on the direct-map RAM path.

### Single most-likely root cause
`arch/x86/mm/init_64.c:508` — dropped `PTE_PFN_MASK` clamp in the 4KB direct-map PTE builder.

### Next experiment to confirm
Patch ONLY line 508 to `__pte((paddr & PHYSICAL_PAGE_MASK) | check_pgprot(prot))`, rebuild PGCL
with CONFIG_PAGE_MMUSHIFT=0, boot the laptop. Expectation: boots clean (matches mainline-base).
Cheap pre-confirmation without a reboot: add a one-shot
`WARN_ON_ONCE((paddr & ~PHYSICAL_PAGE_MASK & ~(MMUPAGE_SIZE-1)) != 0)` (i.e. paddr has bits above
MAXPHYADDR) right before line 508 on the unpatched tree and capture the early-boot log — it should
fire with paddr ≈ 0xfffeedd38xxx on the laptop and never in QEMU, pinpointing the exact firmware
region. (Alternatively `git stash`/branch a one-line build and diff `kernel_physical_mapping_init`
PTE dumps laptop-vs-QEMU around phys 0x8d7ff000 / the 0x96000000-0x973fffff hole.)
