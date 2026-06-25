# QEMU #143 debug instrumentation (non-perturbing guest-MM probes)

Apply to the QEMU tree, then `ninja -C build qemu-system-x86_64`.
Base commit (qemu.git): `384ba786abb18469038f1b7adfe37da6949494c3` (v10.1.4)
```
cd <qemu>; git apply .../qemu-143-debug-instrumentation.patch
```

## What it is
Guest-physical-memory + softmmu-TLB probes that catch PGCL #143-class
rmap/refcount/TLB races from OUTSIDE the guest kernel, so they do NOT perturb
the in-kernel race timing (the "perturbation wall" that defeated in-kernel
printk/ledger probes). Driven by a magic cpuid channel the guest kernel emits on
every page free/alloc.

## Kernel side (the channel — REQUIRED)
`mm/page_alloc.c` `pgcl143_qsig()`: on each __free_pages_prepare (free) and
post_alloc_hook (alloc), execute cpuid leaf 0x5143000{1,0} with
ebx=guest-4K-frame base, ecx=#frames. (Guarded `#if defined(CONFIG_X86_64)`;
no-op without the QEMU side. Un-guarded for PGCL=0 control builds.) Saved
separately as a kernel patch.

## QEMU side (this patch)
- `target/i386/cpu.c` cpu_x86_cpuid: intercepts leaf 0x5143000{0,1}; routes to
  the probes; on a catch dumps the guest kernel stack (PGCL143freepath /
  PGCL143allocpath, kernel-text-filtered).
- `accel/tcg/cputlb.c` TLB-scan: per-4K-frame reverse map of the last USER
  (cpu,vaddr) filled at tlb_set_page_full (x86 mmu_idx 2/3); at FREE verifies the
  softmmu-TLB entry is still live + maps the freed frame (FREE-WHILE-USER-MAPPED);
  at ALLOC the same for reuse (ALLOC-INTO-STALE-MAPPED). Distinguishes
  stale-TLB (pte_maps_frame=0) vs present-dangler. Armed by env PGCL_TLBSCAN.
  Also the PGCL_OVERFLUSH probe (escalate page/range flush -> full).
- `target/i386/helper.c` cpu_x86_update_cr3: records every guest pgd (CR3) into
  the dangle probe's pgd set.
- `target/i386/tcg/system/excp_helper.c` dangling-PTE probe: manual 4-level
  guest page-table walker (pgcl_walk) + a full periodic scan of all tracked pgds
  (pgcl_scan_all) building a frame->(cr3,va) reverse map incl. COLD mappings; at
  FREE walks all pgds at the recorded va (FREE-WHILE-MAPPED) to catch the
  premature-free / dangling-PTE the in-kernel mapcount/bad_page checks cannot see.
  Armed by env PGCL_DANGLE. NOTE: 4-level walk -> run guest with
  `-cpu max,la57=off`; reads bounded to PGCL_RAMLIMIT (set to the -m size, 2G)
  to avoid MMIO core-dumps. (dangle probe = WIP as of this snapshot.)

## How to run (see rmap-ab/*.sh)
`PGCL_TLBSCAN=1` or `PGCL_DANGLE=1` env + `-cpu max,la57=off -smp 8 -m 2G`
2x-oversubscribed via `rmap-ab/iso`, with the abl repro initramfs. The kernel
must be built with the qsig channel.
