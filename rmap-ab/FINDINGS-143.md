# #143 — QEMU-instrumented root-cause findings (2026-06-25, overnight)

## RESOLUTION (added after the discriminator experiments)
**#143 is NOT a TLB-flush bug.** The flush-all discriminator (`pgcl143_flushall`,
gating both `flush_tlb_mm_range` and `arch_tlbbatch_flush` -> `flush_tlb_all`)
drove every TLB-scan catch to 0 yet kill-init **persisted 3/5**. So the
corruption happens with zero stale TLB. The overnight QEMU-TLB hunt found a
**real but secondary** PGCL TLB-staleness phenomenon — not the blocker.

**#143 is the anon rmap / swap EXCLUSIVITY accounting under PGCL sub-PTE units**
(the original framing; same family as #146). DEBUG_VM (on in pgcl4-debug) fires:
- `mm/rmap.c:1620` + `:1635` `folio_add_anon_rmap_ptes` (1521x; `AnonExclusive &&
  _mapcount>0`) — **over-strict asserts** under PGCL (an exclusive cluster has
  `_mapcount = sub-PTEs-1 > 0`); noise, but marks the area.
- `mm/memory.c:5390` `do_swap_page` `check_swap_exclusive` (`__swap_count != 1`).
- paths: swap-in (`do_swap_page`), migration (`kcompactd` ->
  `remove_migration_pte` -> `rmap_walk_anon`), fault.

**Mechanism (prime suspect):** `do_swap_page` (memory.c ~5741) sets
`RMAP_EXCLUSIVE` when `exclusive || folio_ref_count==1`. For a **fork-shared**
anon cluster that was swapped out, if PGCL's per-sub-PTE swap-count mis-determines
`exclusive` (the :5390 WARN shows swap_count != 1 surprises), `AnonExclusive` is
set on a **shared** page. Then `do_wp_page` (memory.c:4902,
`if (PageAnonExclusive(vmf->page) || wp_can_reuse_anon_folio(...))`) **reuses the
page in place (no copy)** — the only in-place reuse path, since
`wp_can_reuse_anon_folio` for a small folio sees refcount>1 and safely copies.
The sharing process's page (often a shared library / code page) is overwritten ->
processes incl. **PID1 segfault at ip=0** -> panic.

`copy_present_ptes` fork-dup (memory.c ~1234-1388) looks **correct** under PGCL
(mapcount += nr, refcount += nr, AnonExclusive cleared once); not the suspect.

**Next session:** confirm the swap-exclusivity hypothesis (instrument
`do_swap_page` to flag `SetPageAnonExclusive` on a cluster whose sibling swap
entries have count>1), then fix exclusivity to be computed **per-cluster** (all 16
sub-PTE swap entries exclusive) rather than per-sub-PTE. Also de-noise the
over-strict asserts (rmap.c:1620/1635, memory.c:5390) to PGCL units. Do NOT apply
a speculative fix unconfirmed — wrong AnonExclusive = silent corruption.

## TL;DR (original, TLB-focused — see RESOLUTION above; superseded)
The pgcl4 laptop blocker (#143) is **reproduced reliably in QEMU** and is a **real,
PGCL-specific kernel bug** — not a QEMU artifact, not benign lazy-TLB/PCID. The
reclaim path frees a user page whose **TLB entry is still live on an active CPU**;
the frame is reused (zeroed by `do_anonymous_page`) and the CPU reads zeros where
a code pointer belongs → processes (incl. **PID1**) **segfault at ip=0** → panic
("Attempted to kill init"). One fork remains open (flush-coverage vs rmap
accounting), settled by the running `pgcl143_flushall` experiment.

## How it was caught (QEMU TCG instrumentation)
Custom qemu in `/home/nyc/src/qemu` (all UNCOMMITTED):
- Kernel emits a magic `cpuid` leaf `0x5143000{1,0}` on every page free/alloc
  (`mm/page_alloc.c` `pgcl143_qsig`: ebx=guest-4K-frame base, ecx=#frames).
- `accel/tcg/cputlb.c` records per-4K-frame the last USER (cpu,vaddr) at
  `tlb_set_page_full` (x86 mmu_idx 2/3); at **free** it verifies the softmmu-TLB
  entry is still live + maps the freed frame → `FREE-WHILE-USER-MAPPED`; at
  **alloc** (new, this session) → `ALLOC-INTO-STALE-MAPPED` (the corruption
  window: frame reused while the previous owner's stale entry still maps it).
- `target/i386/cpu.c` dumps the guest kernel stack on a catch
  (`PGCL143freepath` / `PGCL143allocpath`).

## Evidence
1. **Control (decisive):** pgcl0 (PAGE_MMUSHIFT=0, same repro/qemu/2x-oversub
   `-cpu max -smp 8`): **0/6 FREE catches, 0 kill-init, all reached RRABL DONE.**
   pgcl4: **772** historical FREE catches; **kill-init 4/4** every run.
2. **Not an INVLPGB artifact:** qemu `target/i386` has no INVLPGB → `-cpu max`
   doesn't advertise it → guest takes the IPI `flush_tlb_multi` path = exactly
   what the Intel i7-1370P laptop uses.
3. **Not benign lazy/PCID:** qemu `cpu_x86_update_cr3` (helper.c:181) does an
   unconditional full `tlb_flush` on **every** CR3 write (ignores PCID NOFLUSH;
   no PCID-tagged TLB modelled). So a live entry at free ⇒ **no CR3 write since
   the entry was filled ⇒ the CPU is actively running that mm**, i.e. it is in
   `mm_cpumask` yet the reclaim flush didn't reach it. 413/772 catches are
   **writable**; all are `pte_maps_frame=0` (PTE cleared = stale-TLB, **zero**
   present-danglers); they come in **16-consecutive-frame clusters** (one 64K
   PGCL cluster's sub-MMUPAGEs all stale on one CPU).
4. **Corruption mechanism (consistent):** free path = `shrink_folio_list` →
   `__mem_cgroup_uncharge_folios` (reclaim, after `try_to_unmap_flush`); reused-by
   path = `handle_pte_fault → do_anonymous_page → ... → get_page_from_freelist`;
   death = `repro[] + init[1]: segfault at 0 ip 0000000000000000`, init on CPU6
   (= the run's TLB-catch CPU).

## Open fork (running now: `run-flushall-disc.sh`)
- **(a) flush-coverage gap** — reclaim's `arch_tlbbatch_flush` (full flush over
  `batch->cpumask`) misses an active CPU running the mm. Diagnostic
  `pgcl143_flushall` (arch/x86/mm/tlb.c, cmdline-gated) escalates it to
  `flush_tlb_all()`. **on=0 kill-init ⇒ (a)** confirmed (and a laptop boot
  workaround: `pgcl143_flushall`).
- **(b) rmap refcount/mapcount underflow** — page freed while still mapped (the
  original #143 description). `pgcl143_flushall` would NOT fix it.
  **on>0 ⇒ (b)**; TLB staleness is secondary; resume the rmap-ledger hunt.

## Separate real PGCL bug found (independent of #143)
`arch/x86/mm/tlb.c`: `do_kernel_range_flush` (~line 1508, `addr += PAGE_SIZE`) and
`invlpgb_kernel_range_flush` (~1488, `>> PAGE_SHIFT`) stride by PAGE not MMUPAGE,
ignoring `info->stride_shift` (set to MMUPAGE_SHIFT at `flush_tlb_kernel_range`).
At pgcl4 this under-flushes kernel **vmalloc** ranges 16× (flushes 1 of every 16
sub-MMUPAGEs). The user partial path (`flush_tlb_func`, `addr += 1<<f->stride_shift`)
is correct. Fix: use `info->stride_shift` in both kernel-range loops.

## Uncommitted state (revert before any non-debug build / before commit)
- kernel `/home/nyc/src/linux`: `mm/page_alloc.c` qsig (un-guarded for pgcl0
  control); `arch/x86/mm/tlb.c` `pgcl143_flushall` gate.
- qemu `/home/nyc/src/qemu`: `cputlb.c` TLB-scan + on_alloc; `cpu.c` cpuid hook +
  stack dumps; `excp_helper.c` (superseded walk approach).
- Scripts in `rmap-ab/`: run-allocdetect-ab.sh, run-flushall-disc.sh, iso, etc.
