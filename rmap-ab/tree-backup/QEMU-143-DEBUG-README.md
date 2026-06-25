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

## Update: struct-page reader + underflow scanner (the layer inversion)
QEMU now reads the guest kernel's OWN authoritative struct page fields, removing
the inference/churn ambiguity of page-table walks.
- `pgcl_kwalk()` — KERNEL-va page-table walk (no U-bit; handles 2M/1G huge
  leaves) → guest physical address.
- `pgcl_read_page(cpfn)` — reads `struct page[cpfn]._refcount`/`_mapcount` from
  the vmemmap.  Layout from pahole on the pgcl4 vmlinux:
  `sizeof(struct page)=64, off(_mapcount)=48, off(_refcount)=52`;
  `vmemmap_base=0xffffea0000000000` (nokaslr, 4-level → run `-cpu max,la57=off`);
  vmemmap is indexed by CLUSTER pfn = `qsig_base >> PAGE_MMUSHIFT` (4 @pgcl4).
  Self-test at free prints `PGCL143pgread ... READER-OK` (refcount 0, mapcount -1).
- `pgcl_uf_scan()` — periodic sweep of all clusters' authoritative counts with an
  8-deep per-cluster history ring; flags genuine underflow (`refcount<0`, or a
  small-negative `mapcount` on a REFERENCED page) and dumps the `(rc,mc)`
  trajectory.  CAVEAT: offset 48 is a union — `_mapcount` on in-use pages,
  `page_type` (PGTY_buddy=0xf0000000=-268435456) on free pages — so only read it
  as mapcount when `refcount>0`.
- NEXT (per design): compare kernel `_mapcount` (struct page) vs actual present
  sub-PTE count (pgd walk) per cluster — the discrepancy between the two
  accounting structures is the undercount/underflow directly.

## Update: PTE-vs-struct-page cross-check (compare the two accounting structures)
`pgcl_tally_level`/`pgcl_xcheck_scan`: tally the actual present USER sub-PTEs
mapping each cluster (across LIVE pgds) and compare to the kernel's own
`struct page` per cluster:
 - FREED-WHILE-MAPPED: tally>0 but refcount==0 (PTE maps a freed page)
 - MAPCOUNT-UNDERCOUNT: refcount>0 but _mapcount+1 < tally (kernel forgot PTEs)
 - MAPCOUNT-OVERCOUNT: _mapcount+1 > tally (mappings removed, not decremented)
 - per-scan summary: inuse/match/undercount/overcount/freed
`pgcl_pgd_live` filters dead/reused pgd frames (x86 PGDs are slab-allocated, so
prune-on-free can't catch them) by matching each pgd's vmemmap-PML4 entry to the
current CR3's; also drops PTI user-pgds.  Skips PG_reserved (zero/vdso) and
PG_head (THP) pages.
FINDINGS: steady-state tally == kernel _mapcount EXACTLY (methodology validated);
the undercount catches are TRANSIENT (non-atomic external scan vs concurrent
guest PTE/mapcount updates) -> resolve by next scan.  Caveats: pgd coverage
(npgd low); pgcl0 control needs PGCL_MMUSHIFT=0 (currently hardcoded 4).
NEXT: per-write watch of the mapcount/refcount fields to catch the exact bad
decrement (+RIP), isolating the bug window from normal update windows.

## Update: per-write refcount/mapcount history tracker (the watchpoint of the field)
`accel/tcg/cputlb.c` `pgcl_rc_record` (hooked in `atomic_mmu_lookup`): every
guest atomic RMW on a struct-page `_refcount`(off52)/`_mapcount`(off48) in the
vmemmap records (value-before, sibling-count, cpu, exact guest RIP) into a
per-cluster ring (K=24), dumped at free of an interesting (maxrc>=2) cluster.
Arm with `PGCL_RCHIST=1`.
 - EXACT-RIP fix: `cpu_unwind_state_data` is read-only (`cpu_restore_state`
   corrupts guest state mid-op), but for CF_PCREL kernel TBs x86 saves only the
   LOW page bits in data[0] (`i386_tr_insn_start` masks `pc & ~PAGE_MASK`).  QEMU
   splits TBs at page boundaries, so rebuild the full PC =
   `(get_pc()&TARGET_PAGE_MASK) | (data[0]&~TARGET_PAGE_MASK)`.
 - Resolve RIPs via `nm -n` enclosing symbol (addr2line `-f` returns the
   misleading inlined leaf); see `rmap-ab/resolve-rchist.sh`.
 - excp_helper.c persistence + classification: `pgcl_xcheck_scan` tracks
   consecutive-scan undercount streaks (PGCL143PERSUNDER) and
   `pgcl_classify_cluster` (npgd_mapping + max_subPTE_per_pgd) distinguishes a
   real per-sub-PTE undercount from Contract-A large-anon (mapcount per kernel
   page) false positives.

FINDINGS (decisive): (1) every atomic rc/mc sequence is WELL-FORMED even in
crashing runs (no underflow, never rc<=mc); the big jumps are batched
`folio_put_refs`.  (2) the cross-check "undercount" is a MEASUREMENT RACE, not a
leak: the fresh re-walk shows mapcount == actual current sub-PTEs (npgd=1
maxsub=16), only the earlier tally over-read (32) — a mid-fork transient under
`thread=multi`.  CONFIRMED at `-smp 1`: undercount=0 across all scans.  (3)
PERTURBATION WALL quantified: killinit fires 2/4 with the light per-write tracker
but 0/4 with any per-free pgd walk or heavy I/O.
NET: #143 is a genuine SMP-timing race -> a TRANSIENT premature refcount->0
during a concurrent batch-update window, NOT a persistent miscount (accounting is
correct at rest).  Freeing path = reclaim (shrink_folio_list).
NEXT: (a) catch the one remaining blind spot — NON-ATOMIC stores (`atomic_set` via
set_page_count/page_mapcount_reset) bypass `atomic_mmu_lookup` (TCG inlines
fast-path stores); force the struct-page region through the slow path with a
write-watchpoint so every write (atomic+non-atomic) is logged.  (b) a large
RAM-ring history of every struct-page field write (seq,cpfn,off,oldval,rip,cpu)
so the symptom can be rewound to the causal operation OFFLINE (no perturbing
online checks).
